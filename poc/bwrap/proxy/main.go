// Command proxy is the PoC sandbox's only way out: an HTTP proxy that never connects to a private,
// loopback, link-local or CGNAT address (your LAN, the host, a cloud metadata service) unless the
// config's lan list allows it, and (unless -open) only to the hosts in the config's allow list.
//
//   - https:// (and other TCP): CONNECT host:port, any port
//   - http://: GET http://host:port/path, any port, forwarded
//
// It is also the AI providers' gateway, so their API keys never enter the sandbox: a request to
// the proxy itself, "POST /anthropic/v1/messages", goes to that provider's upstream with the
// configured headers added (values from the proxy's environment), replacing any key the sandbox
// sent.
//
// Usage:
//
//	proxy -config FILE [-open] -listen unix:PATH|HOST:PORT
//	proxy -config FILE -print-env URL    # the sandbox's environment for the gateway, KEY=VALUE
//
// The config (YAML, see ../proxy.yaml) is read again as soon as it changes; one that can't be
// read or parsed keeps the previous rules. Every request is logged to stderr. It runs on Linux,
// macOS and Windows (unix sockets need Windows 10 or later).
package main

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"
	"go.yaml.in/yaml/v3"
)

func main() {
	configPath := flag.String("config", "", "the proxy config (YAML)")
	open := flag.Bool("open", false, "allow every public host, ignoring the config's allow list")
	listen := flag.String("listen", "", "where to listen: unix:PATH, or HOST:PORT")
	printEnv := flag.String("print-env", "", "print the sandbox's environment for a gateway at this URL, and exit")
	flag.Parse()
	if *configPath == "" || flag.NArg() != 0 || (*listen == "") == (*printEnv == "") {
		fmt.Fprintln(os.Stderr, "usage: proxy -config FILE [-open] -listen unix:PATH|HOST:PORT\n       proxy -config FILE -print-env URL")
		os.Exit(2)
	}

	if *printEnv != "" {
		c, err := readConfig(*configPath)
		if err != nil {
			log.Fatal(err)
		}
		for _, line := range c.sandboxEnv(*printEnv) {
			fmt.Println(line)
		}
		return
	}

	p := &proxy{}
	load := func() error {
		c, err := readConfig(*configPath)
		if err != nil {
			return err
		}
		r, err := c.compile(*open)
		if err != nil {
			return err
		}
		p.rules.Store(r)
		log.Printf("config loaded: %s", r)
		return nil
	}
	if err := load(); err != nil {
		log.Fatal(err)
	}
	if err := watch(*configPath, func() {
		if err := load(); err != nil {
			log.Printf("keeping the previous config: %v", err)
		}
	}); err != nil {
		log.Fatal(err)
	}

	listener, err := listenOn(*listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Fatal(http.Serve(listener, p))
}

// listenOn listens on "unix:PATH" (only you can connect) or "HOST:PORT".
func listenOn(address string) (net.Listener, error) {
	path, ok := strings.CutPrefix(address, "unix:")
	if !ok {
		return net.Listen("tcp", address)
	}
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(path, 0o600); err != nil {
			return nil, err
		}
	}
	return listener, nil
}

// config is the YAML file.
type config struct {
	Allow     *[]string            `yaml:"allow"` // required (it may be empty), unless -open
	LAN       []string             `yaml:"lan"`
	Providers map[string]*provider `yaml:"providers"`
}

type provider struct {
	Upstream   string            `yaml:"upstream"`
	KeyEnv     string            `yaml:"key_env"`
	BaseURLEnv string            `yaml:"base_url_env"`
	Headers    map[string]string `yaml:"headers"`
}

func readConfig(path string) (*config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true) // a misspelt key is an error, not silently ignored
	c := &config{}
	if err := decoder.Decode(c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return c, nil
}

// headers returns provider's headers with $VAR expanded from the environment, and the variables
// that are unset (the provider is then left out).
func (pr *provider) headers() (map[string]string, []string) {
	var unset []string
	headers := map[string]string{}
	for name, value := range pr.Headers {
		headers[name] = os.Expand(value, func(variable string) string {
			v := os.Getenv(variable)
			if v == "" {
				unset = append(unset, variable)
			}
			return v
		})
	}
	return headers, unset
}

// sandboxEnv is what the sandbox needs to use the gateway at url: each usable provider's key
// variable as a dummy, and its base URL variable pointing at url/NAME.
func (c *config) sandboxEnv(url string) []string {
	var env []string
	for _, name := range sortedKeys(c.Providers) {
		pr := c.Providers[name]
		if _, unset := pr.headers(); len(unset) > 0 {
			continue
		}
		if pr.KeyEnv != "" {
			env = append(env, pr.KeyEnv+"=go-yolo-gateway")
		}
		if pr.BaseURLEnv != "" {
			env = append(env, pr.BaseURLEnv+"="+url+"/"+name)
		}
	}
	return env
}

// rules are the compiled config: what the sandbox may reach, and the gateways.
type rules struct {
	hosts    []string       // exact domains and "*.suffix" entries; nil: every public host
	lan      []netip.Prefix // private addresses that are allowed too
	gateways map[string]*httputil.ReverseProxy
}

func (r *rules) String() string {
	hosts := "every public host"
	if r.hosts != nil {
		hosts = fmt.Sprintf("%d allowed hosts", len(r.hosts))
	}
	return fmt.Sprintf("%s, LAN %v, gateways %v", hosts, r.lan, sortedKeys(r.gateways))
}

func (c *config) compile(open bool) (*rules, error) {
	r := &rules{gateways: map[string]*httputil.ReverseProxy{}}
	if !open {
		// Required, so an empty or half-written file never means "allow everything".
		if c.Allow == nil {
			return nil, errors.New("the config has no allow list (use -open to allow every public host)")
		}
		r.hosts = []string{}
		for _, host := range *c.Allow {
			r.hosts = append(r.hosts, strings.ToLower(strings.TrimSpace(host)))
		}
	}
	for _, entry := range c.LAN {
		prefix, err := netip.ParsePrefix(entry)
		if err != nil {
			ip, ipErr := netip.ParseAddr(entry)
			if ipErr != nil {
				return nil, fmt.Errorf("lan: %q is not an address or network", entry)
			}
			prefix = netip.PrefixFrom(ip, ip.BitLen())
		}
		r.lan = append(r.lan, prefix.Masked())
	}
	for _, name := range sortedKeys(c.Providers) {
		pr := c.Providers[name]
		target, err := url.Parse(pr.Upstream)
		if err != nil || target.Scheme != "https" {
			return nil, fmt.Errorf("providers: %s: the upstream must be an https:// URL", name)
		}
		headers, unset := pr.headers()
		if len(unset) > 0 {
			log.Printf("gateway: %s left out, %s not set", name, strings.Join(unset, ", "))
			continue
		}
		prefix := "/" + name
		r.gateways[name] = &httputil.ReverseProxy{
			Transport: gatewayTransport,
			Rewrite: func(pr *httputil.ProxyRequest) {
				pr.Out.URL.Path = strings.TrimPrefix(pr.In.URL.Path, prefix)
				pr.Out.URL.RawPath = ""
				pr.SetURL(target)
				// Whatever key the sandbox sent is dropped; only the configured headers go out.
				pr.Out.Header.Del("Authorization")
				pr.Out.Header.Del("X-Api-Key")
				for name, value := range headers {
					pr.Out.Header.Set(name, value)
				}
			},
		}
	}
	return r, nil
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// watch calls changed when the file is written or replaced. It watches the file's directory,
// because editors usually save by writing a new file and renaming it over the old one; events
// within 200ms are taken together, so a file written in several steps is read once, complete.
func watch(path string, changed func()) error {
	abs, err := filepath.Abs(path)
	if err != nil {
		return err
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	if err := watcher.Add(filepath.Dir(abs)); err != nil {
		return err
	}
	go func() {
		var timer <-chan time.Time
		for {
			select {
			case event, ok := <-watcher.Events:
				if !ok {
					return
				}
				if filepath.Clean(event.Name) == abs && event.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Rename) != 0 {
					timer = time.After(200 * time.Millisecond)
				}
			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				log.Printf("watching %s: %v", path, err)
			case <-timer:
				timer = nil
				changed()
			}
		}
	}()
	return nil
}

type proxy struct {
	rules atomic.Pointer[rules] // replaced as a whole when the config changes
}

func (p *proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	rules := p.rules.Load()

	// A request to the proxy itself (a path, not a URL): the AI providers' gateway. The
	// destination comes from the config, not from the sandbox, so no allowlist check.
	if r.Method != http.MethodConnect && !r.URL.IsAbs() {
		name, _, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/"), "/")
		gateway, ok := rules.gateways[name]
		if !ok {
			log.Printf("denied %s %s (no such provider)", r.Method, r.URL.Path)
			http.Error(w, "go-yolo proxy: no provider "+name, http.StatusNotFound)
			return
		}
		log.Printf("gateway %s %s", r.Method, r.URL.Path)
		gateway.ServeHTTP(w, r)
		return
	}

	// The one check, for both kinds of proxied request: the host must be allowed.
	var host string
	switch {
	case r.Method == http.MethodConnect:
		host, _, _ = net.SplitHostPort(r.Host) // "host:port"; "" if malformed
	case r.URL.Scheme == "http":
		host = r.URL.Hostname()
	}
	if host == "" || !rules.isAllowed(host) {
		log.Printf("denied %s %s (not in the allowlist)", r.Method, r.RequestURI)
		http.Error(w, "go-yolo proxy: not in the allowlist", http.StatusForbidden)
		return
	}

	if r.Method == http.MethodConnect {
		tunnel(w, r, rules)
	} else {
		forward(w, r, rules)
	}
}

// isAllowed reports whether host may be reached: an address in a lan entry, or a name in the
// allow list (with -open, every name). The dial then checks the address actually dialled.
func (r *rules) isAllowed(host string) bool {
	if ip, err := netip.ParseAddr(host); err == nil && r.inLAN(ip) {
		return true
	}
	if r.hosts == nil {
		return true
	}
	host = strings.ToLower(strings.TrimSuffix(host, "."))
	for _, entry := range r.hosts {
		if suffix, ok := strings.CutPrefix(entry, "*."); ok {
			if strings.HasSuffix(host, "."+suffix) {
				return true
			}
		} else if host == entry {
			return true
		}
	}
	return false
}

func (r *rules) inLAN(ip netip.Addr) bool {
	ip = ip.Unmap()
	for _, prefix := range r.lan {
		if prefix.Contains(ip) {
			return true
		}
	}
	return false
}

// tunnel connects the client to r.Host ("host:port") and copies bytes both ways (HTTPS).
func tunnel(w http.ResponseWriter, r *http.Request, rules *rules) {
	upstream, err := dial(r.Context(), "tcp", r.Host, rules.inLAN)
	if err != nil {
		log.Printf("denied CONNECT %s: %v", r.Host, err)
		http.Error(w, "go-yolo proxy: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer upstream.Close()
	client, buffered, err := http.NewResponseController(w).Hijack()
	if err != nil {
		log.Printf("error CONNECT %s: %v", r.Host, err)
		return
	}
	defer client.Close()
	log.Printf("allowed CONNECT %s", r.Host)
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection established\r\n\r\n"); err != nil {
		return
	}
	go func() {
		_, _ = io.Copy(upstream, buffered) // the client's bytes, including any already buffered
		if tcp, ok := upstream.(*net.TCPConn); ok {
			_ = tcp.CloseWrite()
		}
	}()
	_, _ = io.Copy(client, upstream)
}

// forward sends a plain http:// request ("GET http://host/path") on and copies the response back.
func forward(w http.ResponseWriter, r *http.Request, rules *rules) {
	request := r.Clone(r.Context())
	request.RequestURI = ""
	request.Header.Del("Proxy-Connection")
	request.Header.Del("Proxy-Authorization")
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return dial(ctx, network, address, rules.inLAN)
		},
		DisableKeepAlives: true,
	}
	response, err := transport.RoundTrip(request)
	if err != nil {
		log.Printf("denied %s %s: %v", r.Method, r.URL, err)
		http.Error(w, "go-yolo proxy: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	log.Printf("allowed %s %s", r.Method, r.URL)
	for key, values := range response.Header {
		w.Header()[key] = values
	}
	w.WriteHeader(response.StatusCode)
	_, _ = io.Copy(w, response.Body)
}

// gatewayTransport sends gateway requests to their upstreams: public addresses only, never
// through another proxy. No response timeout: a model can think for minutes before it answers.
var gatewayTransport = &http.Transport{
	DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return dial(ctx, network, address, func(netip.Addr) bool { return false })
	},
	TLSHandshakeTimeout: 10 * time.Second,
}

// dial connects to address, refusing any non-public IP that inLAN doesn't allow. The check runs
// on the address actually dialled (after DNS), so an allowed name that resolves to a LAN address
// is refused too.
func dial(ctx context.Context, network, address string, inLAN func(netip.Addr) bool) (net.Conn, error) {
	dialer := net.Dialer{
		Timeout: 10 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			addrPort, err := netip.ParseAddrPort(address)
			if err != nil {
				return err
			}
			if ip := addrPort.Addr().Unmap(); !isPublic(ip) && !inLAN(ip) {
				return errors.New(ip.String() + " is not a public address (allow it in the config's lan list)")
			}
			return nil
		},
	}
	return dialer.DialContext(ctx, network, address)
}

var cgnat = netip.MustParsePrefix("100.64.0.0/10") // carrier-grade NAT, also Tailscale

func isPublic(ip netip.Addr) bool {
	return ip.IsGlobalUnicast() && !ip.IsPrivate() && !cgnat.Contains(ip)
}
