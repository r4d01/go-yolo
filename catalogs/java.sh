# shellcheck shell=bash
# The Java catalog: the host's JDKs, Maven, Gradle and their settings.
#
#   jdk     each JDK on the host (/usr/lib/jvm, SDKMAN, ~/.jdks, Gradle's provisioned JDKs, mise,
#           asdf, org.gradle.java.installations.paths, toolchains.xml): apt packages for
#           apt-installed ones, Temurin ones from Adoptium (checked against Adoptium's SHA-256 and
#           the host's release, bin/java and libjvm.so), copies (owned as on the host) for the
#           rest; the default `java` first on PATH; symlinks to them (SDKMAN's current,
#           default-java) kept
#   tool    mvn and gradle, when they are on PATH: their distributions from Apache's and
#           Gradle's release archives (with their checksums), else as `extra tool` does
#   mount   ~/.m2/settings.xml and toolchains.xml, GRADLE_USER_HOME's gradle.properties and
#           init scripts: read-only
#   cache   the Maven local repository and wrapper, Gradle's caches and wrapper: at the host's
#           paths, in the project's volumes (they start empty)
#   env     Java, Maven and Gradle variables set on the host
# With Maven or Gradle items come their domains for --net allowlist (Maven Central, the Gradle
# services, the hosts in settings.xml and the wrappers' download URLs).
#
# The host's ~/.m2 repository and Gradle caches are never read or written.

JAVA_MAVEN_FILES=(pom.xml mvnw)
JAVA_GRADLE_FILES=(build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradlew)
JAVA_ENV_NAMES=(JAVA_HOME JAVA_OPTS JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS)
JAVA_MAVEN_ENV_NAMES=(MAVEN_OPTS MAVEN_ARGS MAVEN_CONFIG M2_HOME MAVEN_HOME)
JAVA_GRADLE_ENV_NAMES=(GRADLE_OPTS GRADLE_HOME GRADLE_USER_HOME)

# A hint for the setup picker: a Maven or Gradle project.
java_detect() { java_uses maven || java_uses gradle; }

# java_uses maven|gradle — true if the project builds with it (a hint for the setup picker).
java_uses() {
  local file files
  if [[ $1 == maven ]]; then files=("${JAVA_MAVEN_FILES[@]}"); else files=("${JAVA_GRADLE_FILES[@]}"); fi
  for file in "${files[@]}"; do
    if [[ -e $file ]]; then return 0; fi
  done
  return 1
}

java_gradle_home() { printf '%s' "${GRADLE_USER_HOME:-$HOME_DIR/.gradle}"; }

# The Maven local repository: settings.xml's <localRepository>, else ~/.m2/repository.
java_maven_repo() {
  local repo
  repo="$(sed -n 's:.*<localRepository>\(.*\)</localRepository>.*:\1:p' "$HOME_DIR/.m2/settings.xml" 2>/dev/null | head -n 1)"
  # shellcheck disable=SC2016 # Maven's literal ${user.home} placeholder, not a shell expansion
  repo=${repo//'${user.home}'/$HOME_DIR}
  printf '%s' "${repo:-$HOME_DIR/.m2/repository}"
}

# The settings files go-yolo can mount, one "build tool<TAB>path" per line (those that exist).
java_settings_files() {
  local gradle_home file
  gradle_home="$(java_gradle_home)"
  for file in "$HOME_DIR/.m2/settings.xml" "$HOME_DIR/.m2/toolchains.xml"; do
    if [[ -f $file ]]; then printf 'maven\t%s\n' "$file"; fi
  done
  for file in "$gradle_home/gradle.properties" "$gradle_home/init.gradle" "$gradle_home/init.gradle.kts" "$gradle_home/init.d"; do
    if [[ -e $file ]]; then printf 'gradle\t%s\n' "$file"; fi
  done
}

# The caches, one "build tool<TAB>id<TAB>path" per line.
java_caches() {
  local gradle_home
  gradle_home="$(java_gradle_home)"
  printf 'maven\tm2-repository\t%s\n' "$(java_maven_repo)"
  printf 'maven\tm2-wrapper\t%s\n' "$HOME_DIR/.m2/wrapper"
  printf 'gradle\tgradle-caches\t%s\n' "$gradle_home/caches"
  printf 'gradle\tgradle-wrapper\t%s\n' "$gradle_home/wrapper"
}

# Candidates for the setup picker (see lib/setup.sh): "mode kind id hint name description".
java_discover() {
  local hint_java=0 hint=0 default="" dir real version name tool file cache path what
  local -A tool_hint=([maven]=0 [gradle]=0)
  if java_detect; then hint_java=1; fi
  if java_uses maven; then tool_hint[maven]=1; fi
  if java_uses gradle; then tool_hint[gradle]=1; fi
  # Nothing to offer on a host without any Java, Maven or Gradle, unless the project uses them.
  if ((!hint_java)) && [[ -z $(java_jdk_dirs) ]] && ! command -v mvn >/dev/null 2>&1 \
     && ! command -v gradle >/dev/null 2>&1; then
    return 0
  fi
  default="$(java_default_home)" || default=""

  while IFS= read -r dir; do
    [[ ! -L $dir ]] || continue   # a symlink comes with the JDK it points to
    real="$(realpath -- "$dir")"
    version="$(java_release "$real" JAVA_VERSION)" || version="?"
    what="JDK $version"
    if [[ $real == "$default" ]]; then what+=", your default java"; fi
    printf 'image\tjdk\t%s\t%s\t%s\t%s (%s) · %s\n' "$real" "$hint_java" "$real" "$what" "$real" "$(java_jdk_how "$real")"
  done < <(java_jdk_dirs)

  for tool in mvn gradle; do
    path="$(command -v "$tool" 2>/dev/null)" || continue
    hint=0
    if [[ $tool == mvn ]] && ((tool_hint[maven])) && [[ ! -e mvnw ]]; then hint=1; fi
    if [[ $tool == gradle ]] && ((tool_hint[gradle])) && [[ ! -e gradlew ]]; then hint=1; fi
    printf 'image\ttool\t%s\t%s\t%s\t%s (%s)\n' "$tool" "$hint" "$tool" "$tool" "$path"
  done
  while IFS=$'\t' read -r tool file; do
    what="$file (read-only)"
    if [[ -f $file ]] && grep -qiE 'password|passwd|secret|token|credential|_auth' -- "$file" 2>/dev/null; then
      what+=" ⚠ may hold credentials"
    fi
    printf 'mount\tmount\t%s\t%s\t%s\t%s\n' "$file" "${tool_hint[$tool]}" "$file" "$what"
  done < <(java_settings_files)
  while IFS=$'\t' read -r tool cache path; do
    printf 'cache\tcache\t%s\t%s\t%s\t%s (a project volume at %s)\n' "$cache" "${tool_hint[$tool]}" "$path" "$cache" "$path"
  done < <(java_caches)

  for name in "${JAVA_ENV_NAMES[@]}" "${JAVA_MAVEN_ENV_NAMES[@]}" "${JAVA_GRADLE_ENV_NAMES[@]}" \
              $(compgen -e | grep '^ORG_GRADLE_PROJECT_' || true); do
    [[ -n ${!name:-} ]] || continue
    if looks_secret "$name" "${!name}"; then
      printf 'env\tenv\t%s\t0\t%s\t%s (⚠ looks like a secret: its value is never shown)\n' "$name" "$name" "$name"
    else
      printf 'env\tenv\t%s\t%s\t%s\t%s=%s\n' "$name" "$hint_java" "$name" "$name" "${!name}"
    fi
  done
}

java_resolve() {
  local name tool cache path maven=0 gradle=0
  catalog_picked java || return 0
  java_plan_jdks
  while IFS= read -r name; do
    plan_tool java "$name" "$(picked_mode java tool "$name")" java_plan_build_tool
  done < <(picked_ids java tool)
  while IFS= read -r name; do
    if [[ -e $name ]]; then plan_mount java "$name"; else plan_add mount java skip "$name" - gone; fi
  done < <(picked_ids java mount)
  while IFS=$'\t' read -r tool cache path; do
    if picked java cache "$cache"; then
      plan_cache java "$path" "$cache"
      if [[ $tool == maven ]]; then maven=1; else gradle=1; fi
    fi
  done < <(java_caches)
  while IFS= read -r name; do plan_env java "$name"; done < <(picked_ids java env)

  if ((maven)) || picked java tool mvn; then java_plan_maven_domains; fi
  if ((gradle)) || picked java tool gradle; then java_plan_gradle_domains; fi
}

# The JDK the host's `java` is: $JAVA_HOME, else the java on PATH (Java 8: the JDK around jre/).
java_default_home() {
  local real home
  if [[ -n ${JAVA_HOME:-} && -x $JAVA_HOME/bin/java ]]; then
    realpath -- "$JAVA_HOME"
    return 0
  fi
  real="$(readlink -f -- "$(command -v java 2>/dev/null)" 2>/dev/null)" || return 1
  [[ $real == */bin/java ]] || return 1
  home=${real%/bin/java}
  if [[ $home == */jre && -x ${home%/jre}/bin/javac ]]; then home=${home%/jre}; fi
  printf '%s' "$home"
}

# Print every directory where the host has a JDK, one per line, the default first: the usual
# install places, Gradle's provisioned JDKs and org.gradle.java.installations.paths, and Maven's
# toolchains.xml. Only directories with a bin/java.
java_jdk_dirs() {
  local gradle_home dir file
  gradle_home="$(java_gradle_home)"
  {
    java_default_home || true
    printf '\n%s' "${JAVA_HOME:-}"
    printf '\n%s' "${GOYOLO_JVM_DIR:-/usr/lib/jvm}"/* "$HOME_DIR"/.sdkman/candidates/java/* "$HOME_DIR"/.jdks/* \
      "$gradle_home"/jdks/* "$HOME_DIR"/.local/share/mise/installs/java/* "$HOME_DIR"/.asdf/installs/java/*
    printf '\n'
    for file in "$gradle_home/gradle.properties" gradle.properties; do
      # org.gradle.java.installations.paths=/opt/jdk17,/opt/jdk21
      sed -n 's/^ *org\.gradle\.java\.installations\.paths *= *//p' "$file" 2>/dev/null | tr ',' '\n'
    done
    sed -n 's:.*<jdkHome>\(.*\)</jdkHome>.*:\1:p' "$HOME_DIR/.m2/toolchains.xml" 2>/dev/null
  } | while IFS= read -r dir; do
    if [[ -n $dir && -x $dir/bin/java ]]; then printf '%s\n' "$dir"; fi
  done | awk '!seen[$0]++'
}

# java_release DIR KEY — a value from a JDK's release file (KEY="value"); fails if there is none.
java_release() {
  local value
  value="$(sed -n "s/^$2=\"\(.*\)\"\$/\1/p" "$1/release" 2>/dev/null | head -n 1)"
  [[ -n $value ]] && printf '%s' "$value"
}

# java_temurin DIR — if DIR is an Eclipse Temurin build Adoptium still serves, print its Adoptium
# API path ("jdk-25.0.3%2B9/linux/x64/jdk/hotspot/normal/eclipse"), from its release file:
#   IMPLEMENTOR="Eclipse Adoptium"  IMPLEMENTOR_VERSION="Temurin-25.0.3+9"  OS_ARCH="x86_64"
java_temurin() {
  local dir=$1 name arch type
  [[ $(java_release "$dir" IMPLEMENTOR) == 'Eclipse Adoptium' && $(java_release "$dir" OS_NAME) == Linux ]] || return 1
  [[ $(java_release "$dir" LIBC || true) != musl ]] || return 1
  [[ $(java_release "$dir" JVM_VARIANT || printf Hotspot) == Hotspot ]] || return 1
  name="$(java_release "$dir" IMPLEMENTOR_VERSION)" || return 1
  name=${name#Temurin-}
  # Java 8 is "1.8.0_422-b05" in FULL_VERSION, "jdk8u422-b05" at Adoptium; later ones "jdk-25.0.3+9".
  if [[ $(java_release "$dir" JAVA_VERSION) == 1.8.0_* ]]; then
    name="$(java_release "$dir" FULL_VERSION)" || return 1
    name="jdk8u${name#1.8.0_}"
  else
    name="jdk-$name"
  fi
  [[ $name =~ ^jdk[-0-9][0-9A-Za-z.+_-]*$ ]] || return 1
  case $(java_release "$dir" OS_ARCH) in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) return 1 ;;
  esac
  case $(java_release "$dir" IMAGE_TYPE || true) in
    JRE) type=jre ;;
    JDK) type=jdk ;;
    *) if [[ -x $dir/bin/javac ]]; then type=jdk; else type=jre; fi ;;
  esac
  printf '%s/linux/%s/%s/hotspot/normal/eclipse' "${name//+/%2B}" "$arch" "$type"
}

# java_jdk_how DIR — how the picker says the JDK gets into the image.
java_jdk_how() {
  local vendor
  if apt_owners "$1" >/dev/null; then printf 'install: apt'
  elif java_temurin "$1" >/dev/null; then printf 'install: Adoptium (sha256)'
  else
    vendor="$(java_release "$1" IMPLEMENTOR)" || vendor="unknown vendor"
    printf 'copy: no recipe for %s' "$vendor"
  fi
}

# Plan the picked JDKs, then the symlinks on the host that point to them.
java_plan_jdks() {
  local default="" dir real version flags owners mode api file files
  default="$(java_default_home)" || default=""
  while IFS= read -r real; do
    if [[ ! -x $real/bin/java ]]; then plan_add toolchain java skip "$real" - gone; continue; fi
    version="$(java_release "$real" JAVA_VERSION)" || version=-
    mode="$(picked_mode java jdk "$real")"
    flags=-
    if [[ $real == "$default" ]]; then flags=on-path; fi
    if [[ $mode == copy ]]; then
      plan_copy toolchain java "$real" "$version" "$(add_flag "$flags" copy-picked)"
    elif owners="$(apt_owners "$real")"; then
      # shellcheck disable=SC2086 # one word per package
      plan_packages java $owners
      if ! plan_has toolchain "$real"; then plan_add toolchain java apt "$real" "$version" "$flags"; fi
    elif api="$(java_temurin "$real")"; then
      files=()
      for file in release bin/java lib/server/libjvm.so; do
        if [[ -f $real/$file ]]; then files+=("$file"); fi
      done
      plan_download toolchain java "$real" "$version" "$flags" "https://api.adoptium.net/v3/binary/version/$api" \
        sha256 "https://api.adoptium.net/v3/checksum/version/$api" "${files[@]}"
    else
      plan_copy toolchain java "$real" "$version" "$(add_flag "$flags" no-recipe)"
    fi
  done < <(picked_ids java jdk)

  # A link from an apt package (Debian's default-java) comes with that package; other links to a
  # picked JDK (SDKMAN's current) are recreated.
  while IFS= read -r dir; do
    if [[ ! -L $dir ]] || ! picked java jdk "$(realpath -- "$dir")"; then continue; fi
    if owners="$(apt_owners "$dir")"; then
      # shellcheck disable=SC2086
      plan_packages java $owners
    elif ! plan_has link "$dir"; then
      plan_add link java link "$dir" "$(realpath -- "$dir")"
    fi
  done < <(java_jdk_dirs)
}

# java_plan_build_tool HOME — install a Maven or Gradle distribution at HOME (where mvn or gradle
# is on the host) from its release archive, at the host's version; fail for anything else.
java_plan_build_tool() {
  local home=$1 real jar version url variant=bin
  real="$(realpath -- "$home")"
  if jar="$(first_file "$real"/lib/maven-core-*.jar)"; then
    version=${jar##*/maven-core-}
    version=${version%.jar}
    [[ $version =~ ^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$ ]] || return 1
    url="https://archive.apache.org/dist/maven/maven-${version%%.*}/$version/binaries/apache-maven-$version-bin.tar.gz"
    plan_download toolchain java "$home" "$version" on-path "$url" sha512 "$url.sha512" bin/mvn "lib/${jar##*/}"
  elif jar="$(first_file "$real"/lib/gradle-base-services-[0-9]*.jar)"; then
    version=${jar##*/gradle-base-services-}
    version=${version%.jar}
    [[ $version =~ ^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$ ]] || return 1
    # The -all distribution also has the sources and docs.
    if [[ -d $real/src || -d $real/docs ]]; then variant=all; fi
    url="https://services.gradle.org/distributions/gradle-$version-$variant.zip"
    plan_download toolchain java "$home" "$version" on-path "$url" sha256 "$url.sha256" bin/gradle "lib/${jar##*/}"
  else
    return 1
  fi
}

java_plan_maven_domains() {
  plan_domain java repo.maven.apache.org
  plan_domain java repo1.maven.org
  # Mirrors and repositories in settings.xml, and the Maven wrapper's download URLs.
  java_plan_url_domains < <(
    sed -n 's:.*<url>\(.*\)</url>.*:\1:p' "$HOME_DIR/.m2/settings.xml" 2>/dev/null
    sed -n 's/^ *\(distributionUrl\|wrapperUrl\) *= *//p' .mvn/wrapper/maven-wrapper.properties 2>/dev/null
  )
}

java_plan_gradle_domains() {
  local domain
  for domain in services.gradle.org downloads.gradle.org plugins.gradle.org plugins-artifacts.gradle.org \
                repo.maven.apache.org repo1.maven.org; do
    plan_domain java "$domain"
  done
  # distributionUrl=https\://services.gradle.org/distributions/gradle-9.6.0-bin.zip
  java_plan_url_domains < <(sed -n 's/^ *distributionUrl *= *//p' gradle/wrapper/gradle-wrapper.properties 2>/dev/null)
}

# Allow the host of each URL read from stdin (one per line; "\:" as in .properties files is fine).
java_plan_url_domains() {
  local url host
  while IFS= read -r url; do
    url=${url//\\:/:}
    [[ $url == *://* ]] || continue
    host=${url#*://}
    host=${host%%/*}
    host=${host##*@}
    plan_domain java "${host%%:*}"
  done
}

# --parity probe (see lib/parity.sh): the default JDK and its settings, the JDKs Gradle and
# Maven can find in the usual places, and Maven or Gradle if they are on PATH.
java_probe() {
  local dir jdks=""
  if command -v java >/dev/null 2>&1; then
    printf 'java version\t%s\n' "$(java -version 2>&1 | tr '\n' ' ')"
    # "    java.home = /usr/lib/jvm/java-21-openjdk-amd64" → "java java.home<TAB>/usr/lib/..."
    java -XshowSettings:properties -version 2>&1 | awk '
      $2 == "=" && $1 ~ /^(java\.home|java\.version|java\.vendor|file\.encoding|native\.encoding|sun\.jnu\.encoding|user\.language|user\.country|user\.home|user\.dir|user\.name)$/ {
        key = $1; $1 = ""; $2 = ""; sub(/^ +/, ""); printf "java %s\t%s\n", key, $0 }'
  else
    printf 'java\t(missing)\n'
  fi
  if command -v javac >/dev/null 2>&1; then
    printf 'javac\t%s\n' "$(javac -version 2>&1 | head -n 1)"
  else
    printf 'javac\t(missing)\n'
  fi
  for dir in "${GOYOLO_JVM_DIR:-/usr/lib/jvm}"/* "$HOME"/.sdkman/candidates/java/* "$HOME"/.jdks/* \
             "${GRADLE_USER_HOME:-$HOME/.gradle}"/jdks/*; do
    if [[ -x $dir/bin/java ]]; then jdks+="$dir "; fi
  done
  printf 'java jdks\t%s\n' "$jdks"
  if command -v mvn >/dev/null 2>&1; then printf 'mvn version\t%s\n' "$(mvn -v 2>&1 | head -n 3 | tr '\n' ' ')"; fi
  if command -v gradle >/dev/null 2>&1; then printf 'gradle version\t%s\n' "$(gradle --version 2>&1 | grep -m1 '^Gradle')"; fi
}
