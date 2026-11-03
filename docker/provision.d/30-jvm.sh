#!/usr/bin/env bash
# JVM toolchain: OpenJDK 21 (apt), Maven (apt), Gradle (pinned zip), sbt
# (Scala's Debian repository).
set -euo pipefail
# shellcheck source=/dev/null
. "${LBX_PROVISION_LIB:-/opt/llm-in-a-box/provision-lib.sh}"

GRADLE_VERSION="${GRADLE_VERSION:-9.7.1}"

if ! have java || ! have mvn; then
    log "installing openjdk-21 + maven"
    apt_install openjdk-21-jdk maven
else
    log "openjdk + maven already present"
fi

if [ ! -x "/opt/gradle-${GRADLE_VERSION}/bin/gradle" ]; then
    log "installing gradle ${GRADLE_VERSION}"
    $SUDO curl -fsSL \
        "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" \
        -o /tmp/gradle.zip
    $SUDO unzip -q /tmp/gradle.zip -d /opt
    $SUDO ln -sfn "/opt/gradle-${GRADLE_VERSION}" /opt/gradle
    $SUDO rm -f /tmp/gradle.zip
    # On the system PATH via a symlink, not ENV PATH: the image's ENV is lost
    # in the vm guest's non-interactive ssh sessions (same fix as bun/aft/cargo).
    $SUDO ln -sfn /opt/gradle/bin/gradle /usr/local/bin/gradle
else
    # Re-assert the PATH symlink even when the unpacked tree is already there
    # (an image built before the symlink existed, or a re-run after lbx-setup).
    $SUDO ln -sfn /opt/gradle/bin/gradle /usr/local/bin/gradle
    log "gradle already present"
fi

if ! have sbt; then
    log "installing sbt"
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" \
        | $SUDO gpg --dearmor -o /etc/apt/trusted.gpg.d/sbt.gpg
    echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" \
        | $SUDO tee /etc/apt/sources.list.d/sbt.list >/dev/null
    apt_install sbt
else
    log "sbt already present"
fi

record jvm
log "jvm toolchain ready"
