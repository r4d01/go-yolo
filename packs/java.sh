# shellcheck shell=bash
# The Java pack, for Maven and Gradle projects: the host's JDKs, build tools and settings.
#
#   toolchain  every JDK the host's Gradle or Maven could pick as a toolchain: apt packages for
#              apt-installed ones, copies (owned as on the host) for the rest; the default `java`
#              first on PATH. Maven or Gradle themselves, if the project has no wrapper.
#   link       symlinks to them (SDKMAN's current, /usr/lib/jvm/default-java, ...)
#   mount      ~/.m2/settings.xml and toolchains.xml, GRADLE_USER_HOME's gradle.properties and
#              init scripts: read-only
#   cache      the Maven local repository and wrapper, Gradle's caches and wrapper: at the host's
#              paths, in the project's volumes (they start empty)
#   env        Java, Maven and Gradle variables set on the host
#   domain     Maven Central and the Gradle services; the hosts in settings.xml and the wrappers
#
# The host's ~/.m2 repository and Gradle caches are never read or written.

JAVA_MAVEN_FILES=(pom.xml mvnw)
JAVA_GRADLE_FILES=(build.gradle build.gradle.kts settings.gradle settings.gradle.kts gradlew)

java_detect() { java_uses maven || java_uses gradle; }

# java_uses maven|gradle — true if the project builds with it.
java_uses() {
  local file files
  if [[ $1 == maven ]]; then files=("${JAVA_MAVEN_FILES[@]}"); else files=("${JAVA_GRADLE_FILES[@]}"); fi
  for file in "${files[@]}"; do
    if [[ -e $file ]]; then return 0; fi
  done
  return 1
}

java_resolve() {
  local gradle_home=${GRADLE_USER_HOME:-$HOME_DIR/.gradle} name
  java_plan_jdks "$gradle_home"
  if java_uses maven; then
    if [[ ! -e mvnw ]]; then plan_tool java mvn; fi
    java_plan_maven
  fi
  if java_uses gradle; then
    if [[ ! -e gradlew ]]; then plan_tool java gradle; fi
    java_plan_gradle "$gradle_home"
  fi

  for name in JAVA_HOME JAVA_OPTS JAVA_TOOL_OPTIONS _JAVA_OPTIONS JDK_JAVA_OPTIONS; do
    plan_env java "$name"
  done
  if java_uses maven; then
    for name in MAVEN_OPTS MAVEN_ARGS MAVEN_CONFIG M2_HOME MAVEN_HOME; do plan_env java "$name"; done
  fi
  if java_uses gradle; then
    for name in GRADLE_OPTS GRADLE_HOME GRADLE_USER_HOME $(compgen -e | grep '^ORG_GRADLE_PROJECT_' || true); do
      plan_env java "$name"
    done
  fi
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

# Print every directory where the host's Gradle or Maven could find a JDK, one per line, the
# default first: the usual install places; for Gradle its provisioned JDKs and
# org.gradle.java.installations.paths, for Maven toolchains.xml. Only directories with a bin/java.
java_jdk_dirs() {
  local gradle_home=$1 dir file
  {
    java_default_home || true
    printf '\n%s' "${JAVA_HOME:-}"
    printf '\n%s' "${GOYOLO_JVM_DIR:-/usr/lib/jvm}"/* "$HOME_DIR"/.sdkman/candidates/java/* "$HOME_DIR"/.jdks/* \
      "$HOME_DIR"/.local/share/mise/installs/java/* "$HOME_DIR"/.asdf/installs/java/*
    printf '\n'
    if java_uses gradle; then
      printf '%s\n' "$gradle_home"/jdks/*
      for file in "$gradle_home/gradle.properties" gradle.properties; do
        # org.gradle.java.installations.paths=/opt/jdk17,/opt/jdk21
        sed -n 's/^ *org\.gradle\.java\.installations\.paths *= *//p' "$file" 2>/dev/null | tr ',' '\n'
      done
    fi
    if java_uses maven; then
      sed -n 's:.*<jdkHome>\(.*\)</jdkHome>.*:\1:p' "$HOME_DIR/.m2/toolchains.xml" 2>/dev/null
    fi
  } | while IFS= read -r dir; do
    if [[ -n $dir && -x $dir/bin/java ]]; then printf '%s\n' "$dir"; fi
  done | awk '!seen[$0]++'
}

# Plan every JDK: the real directories first, then the symlinks to them.
java_plan_jdks() {
  local gradle_home=$1 default="" dir real version flags owners
  local links=()
  default="$(java_default_home)" || default=""
  while IFS= read -r dir; do
    if [[ -L $dir ]]; then links+=("$dir"); continue; fi
    real="$(realpath -- "$dir")"
    version="$(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$real/release" 2>/dev/null)"
    flags=-
    if [[ $real == "$default" ]]; then flags=on-path; fi
    if owners="$(apt_owners "$real")"; then
      # shellcheck disable=SC2086 # one word per package
      plan_packages java $owners
      if ! plan_has toolchain "$real"; then plan_add toolchain java apt "$real" "${version:--}" "$flags"; fi
    else
      plan_copy toolchain java "$real" "${version:--}" "$flags"
    fi
  done < <(java_jdk_dirs "$gradle_home")

  # A link from an apt package (Debian's default-java) comes with that package.
  for dir in "${links[@]}"; do
    if owners="$(apt_owners "$dir")"; then
      # shellcheck disable=SC2086
      plan_packages java $owners
    elif ! plan_has link "$dir"; then
      java_plan_jdk_dir_of_link "$dir" "$default"
    fi
  done
}

# A symlinked JDK that isn't from apt: plan its real directory (if not yet) and the link.
java_plan_jdk_dir_of_link() {
  local dir=$1 default=$2 real flags=-
  real="$(realpath -- "$dir")"
  if [[ $real == "$default" ]]; then flags=on-path; fi
  plan_copy toolchain java "$dir" "$(sed -n 's/^JAVA_VERSION="\(.*\)"/\1/p' "$real/release" 2>/dev/null)" "$flags"
  if ! plan_has link "$dir"; then plan_add link java link "$dir" "$real"; fi
}

java_plan_maven() {
  local m2="$HOME_DIR/.m2" file repo
  for file in settings.xml toolchains.xml; do
    if [[ -f $m2/$file ]]; then plan_mount java "$m2/$file"; fi
  done
  # The local repository: settings.xml's <localRepository>, else ~/.m2/repository.
  repo="$(sed -n 's:.*<localRepository>\(.*\)</localRepository>.*:\1:p' "$m2/settings.xml" 2>/dev/null | head -n 1)"
  repo=${repo//'${user.home}'/$HOME_DIR}
  repo=${repo:-$m2/repository}
  plan_cache java "$repo" m2-repository
  plan_cache java "$m2/wrapper" m2-wrapper

  plan_domain java repo.maven.apache.org
  plan_domain java repo1.maven.org
  # Mirrors and repositories in settings.xml, and the Maven wrapper's download URLs.
  java_plan_url_domains < <(
    sed -n 's:.*<url>\(.*\)</url>.*:\1:p' "$m2/settings.xml" 2>/dev/null
    sed -n 's/^ *\(distributionUrl\|wrapperUrl\) *= *//p' .mvn/wrapper/maven-wrapper.properties 2>/dev/null
  )
}

java_plan_gradle() {
  local gradle_home=$1 file
  for file in gradle.properties init.gradle init.gradle.kts; do
    if [[ -f $gradle_home/$file ]]; then plan_mount java "$gradle_home/$file"; fi
  done
  if [[ -d $gradle_home/init.d ]]; then plan_mount java "$gradle_home/init.d"; fi

  plan_cache java "$gradle_home/caches" gradle-caches
  plan_cache java "$gradle_home/wrapper" gradle-wrapper

  for file in services.gradle.org downloads.gradle.org plugins.gradle.org plugins-artifacts.gradle.org \
              repo.maven.apache.org repo1.maven.org; do
    plan_domain java "$file"
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
