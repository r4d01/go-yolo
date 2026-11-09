#!/usr/bin/env bash
# The Java catalog and extra tool.
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# JDKs: an apt one (the default java) with Debian's default-java link, an IntelliJ one, an
# SDKMAN one with its "current" link, and one Gradle provisioned.
new_jdk() {
  mkdir -p "$1/bin"
  cp "$REPO_DIR/tests/fixtures/go" "$1/bin/java"
  chmod +x "$1/bin/java"
  printf 'JAVA_VERSION="%s"\n' "$2" >"$1/release"
}
new_jdk "$TEST_DIR/jvm/java-21" 21.0.1
ln -s java-21 "$TEST_DIR/jvm/default-java"
new_jdk "$TEST_HOME/.jdks/openjdk-27" 27
new_jdk "$TEST_HOME/.sdkman/candidates/java/17.0.9-tem" 17.0.9
ln -s 17.0.9-tem "$TEST_HOME/.sdkman/candidates/java/current"
new_jdk "$TEST_HOME/.gradle/jdks/eclipse_adoptium-25" 25.0.3
TEMURIN="$TEST_HOME/.gradle/jdks/eclipse_adoptium-25"
printf 'IMPLEMENTOR="Eclipse Adoptium"\nIMPLEMENTOR_VERSION="Temurin-25.0.3+9"\nOS_NAME="Linux"\nOS_ARCH="x86_64"\nIMAGE_TYPE="JDK"\n' >>"$TEMURIN/release"
: >"$TEMURIN/provisioned.ok"
mkdir -p "$TEST_HOME/.gradle/caches/modules-2" "$TEST_HOME/.gradle/wrapper/dists/gradle-9.6.0-bin"
: >"$TEST_HOME/.gradle/wrapper/dists/gradle-9.6.0-bin/gradle-9.6.0-bin.zip.ok"
printf 'systemProp.http.proxyPassword=hunter2\n' >"$TEST_HOME/.gradle/gradle.properties"
printf 'openjdk-21-jre-headless:amd64: %s\ndefault-jre-headless: %s\n' \
  "$TEST_DIR/jvm/java-21" "$TEST_DIR/jvm/default-java" >"$TEST_DIR/dpkg-S"
cat >>"$TEST_DIR/apt-policy" <<'POLICY'
openjdk-21-jre-headless:
  Installed: 21.0.1+12-1
  Candidate: 21.0.1+12-1
  Version table:
 *** 21.0.1+12-1 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
        100 /var/lib/dpkg/status
default-jre-headless:
  Installed: 2:1.21-76
  Candidate: 2:1.21-76
  Version table:
 *** 2:1.21-76 500
        500 http://deb.debian.org/debian trixie/main amd64 Packages
        100 /var/lib/dpkg/status
POLICY

# A Gradle project with a wrapper.
JAVA_PROJECT="$TEST_HOME/project"
mkdir -p "$JAVA_PROJECT/gradle/wrapper"
: >"$JAVA_PROJECT/build.gradle.kts"
: >"$JAVA_PROJECT/gradlew"
printf 'distributionUrl=https\\://gradle.example.com/gradle-9.6.0-bin.zip\n' >"$JAVA_PROJECT/gradle/wrapper/gradle-wrapper.properties"
rm -rf -- "$STATE"
TEST_ENV=(JAVA_HOME="$TEST_DIR/jvm/java-21" GOYOLO_TOOLS=java)
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $TEST_DIR/jvm/java-21 (21.0.1) [java]  first on PATH"
expect_plan 'package   openjdk-21-jre-headless=21.0.1+12-1 [java]'
expect_plan 'package   default-jre-headless=2:1.21-76 [java]'
expect_plan "toolchain $TEST_HOME/.jdks/openjdk-27 (27) [java]  owned by you, as on the host"
expect_plan "toolchain $TEST_HOME/.sdkman/candidates/java/17.0.9-tem (17.0.9) [java]  owned by you"
expect_plan "link      $TEST_HOME/.sdkman/candidates/java/current → $TEST_HOME/.sdkman/candidates/java/17.0.9-tem [java]"
temurin_hash="$(cd "$TEMURIN" && sha256sum release bin/java | sha256sum | cut -c1-16)"
expect_plan "toolchain $TEMURIN (25.0.3, $temurin_hash) [java]  owned by you, as on the host; installed from api.adoptium.net, checked against its checksum and the host's files"
expect_plan "toolchain $TEST_HOME/.jdks/openjdk-27 (27) [java]  owned by you, as on the host; copied from the host: no recipe knows how to install it"
expect_plan "mount     $TEST_HOME/.gradle/gradle.properties (read-only) [java]  ⚠ may hold credentials: the agent can read it"
expect_plan "cache     $TEST_HOME/.gradle/caches (project volume gradle-caches) [java]"
expect_plan "cache     $TEST_HOME/.gradle/wrapper (project volume gradle-wrapper) [java]"
[[ $plan_text != *seed* && $plan_text != *GRADLE_RO_DEP_CACHE* ]] || fail "the host's Gradle cache is still a seed"
expect_plan "env       JAVA_HOME=$TEST_DIR/jvm/java-21 [java]"
expect_plan 'domain    gradle.example.com [java]'
expect_plan "GOYOLO_TOOLS is no longer used"
[[ $plan_text != *"link      $TEST_DIR/jvm/default-java"* && $plan_text != *"toolchain $TEST_DIR/jvm/java-21 (21.0.1) [java]  owned"* ]] \
  || fail 'the apt JDK or its apt link was planned as a copy'
[[ $plan_text != *'tools     gradle'* ]] || fail 'a project with gradlew got a host gradle item'

dry_run shell
printf '%s\n' "${ARGS[@]}" | grep -qxF "GOYOLO_TOOL_PATH=$TEST_DIR/jvm/java-21/bin" \
  || fail 'only the default JDK should be on PATH'
cp /dev/null "$TEST_DIR/docker.log"
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
dockerfile="$(cat "$STATE/build/Dockerfile")"
for jdk in "$TEST_HOME/.jdks/openjdk-27" "$TEST_HOME/.sdkman/candidates/java/17.0.9-tem"; do
  [[ $dockerfile == *"--chown=$(id -u):$(id -g) [\"/\", \"$jdk/\"]"* ]] || fail "$jdk is not copied with your ownership"
done
api=jdk-25.0.3%2B9/linux/x64/jdk/hotspot/normal/eclipse
expected="USER $(id -u):$(id -g)
RUN /opt/go-yolo/scripts/install-archive.sh https://api.adoptium.net/v3/binary/version/$api sha256 https://api.adoptium.net/v3/checksum/version/$api $TEMURIN $temurin_hash --empty /tmp/go-yolo-empty-1 -- release bin/java
USER root"
[[ $dockerfile == *"$expected"* ]] || fail "the Temurin JDK is not installed from Adoptium as you (with Gradle's marker): $dockerfile"
[[ $dockerfile != *"\"$TEMURIN/\""* ]] || fail 'the Temurin JDK is copied too'
[[ $dockerfile == *"COPY files-empty/1 /tmp/go-yolo-empty-1"* && $(cat "$STATE/build/files-empty/1") == provisioned.ok ]] \
  || fail "Gradle's empty marker file is not recreated" 
[[ $dockerfile != *"\"$TEST_DIR/jvm/java-21/\""* ]] || fail 'the apt JDK is copied instead of installed'
[[ $dockerfile == *"ln -sfn $TEST_HOME/.sdkman/candidates/java/17.0.9-tem $TEST_HOME/.sdkman/candidates/java/current"* ]] \
  || fail 'the SDKMAN current link is not recreated'
pass "Java: every JDK Gradle could pick is planned (apt, from Adoptium, or copied), the default first on PATH; Gradle's caches are project-local"

# A Maven project with a wrapper and a settings.xml with its own local repository and a mirror.
rm -rf -- "$STATE" "$JAVA_PROJECT"/{build.gradle.kts,gradlew,gradle}
mkdir -p "$JAVA_PROJECT/.mvn/wrapper" "$TEST_HOME/.m2" "$TEST_HOME/m2repo"
: >"$JAVA_PROJECT/pom.xml"
: >"$JAVA_PROJECT/mvnw"
printf 'distributionUrl=https://maven.example.org/apache-maven-3.9.9-bin.zip\n' >"$JAVA_PROJECT/.mvn/wrapper/maven-wrapper.properties"
cat >"$TEST_HOME/.m2/settings.xml" <<'XML'
<settings>
  <localRepository>${user.home}/m2repo</localRepository>
  <mirrors><mirror><url>https://nexus.example.com/repository/maven/</url></mirror></mirrors>
</settings>
XML
TEST_ENV=(JAVA_HOME="$TEST_DIR/jvm/java-21" MAVEN_ARGS=-ntp)
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "mount     $TEST_HOME/.m2/settings.xml (read-only) [java]"
expect_plan "cache     $TEST_HOME/m2repo (project volume m2-repository) [java]"
expect_plan 'env       MAVEN_ARGS=-ntp [java]'
[[ $plan_text != *seed* ]] || fail "the host's Maven repository is still a seed"
expect_plan 'domain    nexus.example.com [java]'
expect_plan 'domain    maven.example.org [java]'
[[ $plan_text != *'gradle-caches'* && $plan_text != *'gradle-wrapper'* && $plan_text != *gradle.properties* ]] \
  || fail 'a Maven project got Gradle caches or settings'
rm -rf -- "$STATE" "$JAVA_PROJECT"/{pom.xml,mvnw,.mvn} "$TEST_HOME/.m2" "$TEST_HOME/m2repo"
TEST_ENV=()
pass "Java: Maven's settings, local repository (as a project volume) and repository hosts are planned"

# extra tool: kotlin linked from a general bin/ is its real install; gradle through SDKMAN's
# current link keeps the link; a plain file in a bin/ directory can't be copied on its own.
mkdir -p "$TEST_DIR/opt/kotlin/bin" "$TEST_HOME/.sdkman/candidates/gradle/8.5/bin"
for tool in "$TEST_DIR/opt/kotlin/bin/kotlin" "$TEST_HOME/.sdkman/candidates/gradle/8.5/bin/gradle" "$TEST_DIR/bin/plaintool"; do
  printf '#!/bin/sh\n' >"$tool"
  chmod +x "$tool"
done
ln -s "$TEST_DIR/opt/kotlin/bin/kotlin" "$TEST_DIR/bin/kotlin"
ln -s 8.5 "$TEST_HOME/.sdkman/candidates/gradle/current"
mkdir -p "$STATE"
printf 'extra tool kotlin\nextra tool gradle\nextra tool plaintool\nextra tool no-such-tool\n' >"$STATE/config"
TEST_ENV=(PATH="$TEST_HOME/.sdkman/candidates/gradle/current/bin:$TEST_DIR/bin:/usr/bin:/bin")
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $TEST_DIR/opt/kotlin (kotlin) [extra]"
expect_plan "toolchain $TEST_HOME/.sdkman/candidates/gradle/8.5 (8.5) [extra]  owned by you, as on the host; first on PATH"
expect_plan "link      $TEST_HOME/.sdkman/candidates/gradle/current → $TEST_HOME/.sdkman/candidates/gradle/8.5 [extra]"
expect_plan "tools     plaintool (-) [extra]  ⚠ not copied: it isn't installed as <dir>/bin/<name>"
expect_plan "tools     no-such-tool (-) [extra]  ⚠ not on the host's PATH"
rm -rf -- "$STATE" "$TEST_DIR/bin"/{kotlin,plaintool}
TEST_ENV=()
pass 'extra tool brings a host command: its install directory (keeping a current-style link), on PATH'

# mvn and gradle on PATH, picked from the Java catalog: their distributions from the release
# archives at the host's versions (SDKMAN's current link kept); with the copy mode a copy.
mkdir -p "$TEST_DIR/opt/maven/bin" "$TEST_DIR/opt/maven/lib" "$TEST_HOME/.sdkman/candidates/gradle/8.5/lib"
printf '#!/bin/sh\n' >"$TEST_DIR/opt/maven/bin/mvn"
chmod +x "$TEST_DIR/opt/maven/bin/mvn"
: >"$TEST_DIR/opt/maven/lib/maven-core-3.9.9.jar"
: >"$TEST_HOME/.sdkman/candidates/gradle/8.5/lib/gradle-base-services-8.5.jar"
mkdir -p "$STATE"
printf 'image java tool mvn\nimage java tool gradle\n' >"$STATE/config"
TEST_ENV=(PATH="$TEST_HOME/.sdkman/candidates/gradle/current/bin:$TEST_DIR/opt/maven/bin:$TEST_DIR/bin:/usr/bin:/bin")
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $TEST_DIR/opt/maven (3.9.9, "
expect_plan "installed from archive.apache.org"
expect_plan "toolchain $TEST_HOME/.sdkman/candidates/gradle/8.5 (8.5, "
expect_plan "installed from services.gradle.org"
expect_plan "link      $TEST_HOME/.sdkman/candidates/gradle/current → $TEST_HOME/.sdkman/candidates/gradle/8.5 [java]"
TEST_IMAGE_STATUS=1 launch --yes shell 2>/dev/null
dockerfile="$(cat "$STATE/build/Dockerfile")"
url=https://archive.apache.org/dist/maven/maven-3/3.9.9/binaries/apache-maven-3.9.9-bin.tar.gz
[[ $dockerfile == *"install-archive.sh $url sha512 $url.sha512 $TEST_DIR/opt/maven "*" -- bin/mvn lib/maven-core-3.9.9.jar"* ]] \
  || fail "Maven is not installed from Apache's archive: $dockerfile"
url=https://services.gradle.org/distributions/gradle-8.5-bin.zip
[[ $dockerfile == *"install-archive.sh $url sha256 $url.sha256 $TEST_HOME/.sdkman/candidates/gradle/8.5 "*" -- bin/gradle lib/gradle-base-services-8.5.jar"* ]] \
  || fail "Gradle is not installed from its distribution: $dockerfile"
printf 'copy java tool gradle\n' >"$STATE/config"
rm -f -- "$STATE/plan"
plan_text="$(launch --dry-run --plan shell 2>&1 >/dev/null)"
expect_plan "toolchain $TEST_HOME/.sdkman/candidates/gradle/8.5 (8.5) [java]  owned by you, as on the host; first on PATH; copied from the host, as .go-yolo/config asks"
rm -rf -- "$STATE"
TEST_ENV=()
pass 'Java: Maven and Gradle on PATH are installed from their release archives, at the host'"'"'s versions'
