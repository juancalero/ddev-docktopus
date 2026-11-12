#!/usr/bin/env bats

# NOTE: this meta add-on installs its children from GitHub, so the release
# test requires all child repositories to be published (with releases):
#   ddev/ddev-drupal-solr, ddev/ddev-varnish, ddev/ddev-adminer,
#   julienloizelet/ddev-portainer, trebormc/ddev-opencode and every
#   juancalero/ddev-docktopus-* add-on.
# To test locally with checked-out children, install them by hand first
# (ddev add-on get /path/to/each --skip-deps) and then install this
# directory with DDEV_DOCKTOPUS_SKIP_DEPS=1.

setup() {
  set -eu -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=juancalero/ddev-docktopus

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  export CI=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  # All the extra services must be healthy after the restart.
  run ddev exec -s solr curl -sf "http://localhost:8983/solr/dev/admin/ping"
  assert_output --partial '"status":"OK"'

  # ldapsearch uses the default filter (objectClass=*) when none is given;
  # passing it explicitly breaks because ddev exec re-runs the command via
  # `sh -c` and the bare parentheses end up unquoted.
  run ddev exec -s openldap ldapsearch -x -H ldap://localhost -b "dc=miempresa,dc=local" -D "cn=admin,dc=miempresa,dc=local" -w admin dn
  assert_success

  run ddev exec -s postgres pg_isready
  assert_success

  # The seeded agent-repo configuration must exist.
  assert [ -f .ddev/.env.agents-sync ]
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}
