#!/usr/bin/env bash
#: Free TAK Server Installation Script (Modified for Debian)
#: Original Author: John
#: Modified for Debian compatibility

# enforce failfast
set -o errexit
set -o nounset
set -o pipefail

# This disables Apt's "restart services" interactive dialog
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_SUSPEND=1
NEEDRESTART=

# trap or catch signals and direct execution to cleanup
trap cleanup SIGINT SIGTERM ERR EXIT

DEFAULT_REPO="https://github.com/FreeTAKTeam/FreeTAKHub-Installation.git"
REPO=${REPO:-$DEFAULT_REPO}
DEFAULT_BRANCH="main"
BRANCH=${BRANCH:-$DEFAULT_BRANCH}
CBRANCH=${CBRANCH:-}

DEFAULT_INSTALL_TYPE="latest"
INSTALL_TYPE="${INSTALL_TYPE:-$DEFAULT_INSTALL_TYPE}"

PY3_VER_LEGACY="3.8"
PY3_VER_STABLE="3.11"

STABLE_FTS_VERSION="2.0.66"
LEGACY_FTS_VERSION="1.9.9.6"
LATEST_FTS_VERSION=$(curl -s https://pypi.org/pypi/FreeTAKServer/json | python3 -c "import sys, json; print(json.load(sys.stdin)['info']['version'])")

FTS_VENV="${HOME}/fts.venv"

DRY_RUN=0

hsep="*********************"

###############################################################################
# Add coloration to output for highlighting or emphasizing words
###############################################################################
function setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m'
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
  else
    NOFORMAT=''
    RED=''
    GREEN=''
    BLUE=''
    YELLOW=''
  fi
}

###############################################################################
# Print out helpful message.
###############################################################################
function usage() {
  cat <<USAGE_TEXT
Usage: $(basename "${BASH_SOURCE[0]}") [<optional-arguments>]

Install Free TAK Server and components.

Available options:

-h, --help       Print help
-v, --verbose    Print script debug info
-c, --check      Check for compatibility issues while installing
    --core       Install FreeTAKServer, UI, and Web Map
    --latest     [DEFAULT] Install latest version (v$LATEST_FTS_VERSION)
-s, --stable     Install latest stable version (v$STABLE_FTS_VERSION)
-l, --legacy     Install legacy version (v$LEGACY_FTS_VERSION)
    --repo       Replaces with specified ZT Installer repository [DEFAULT ${DEFAULT_REPO}]
    --branch     Use specified ZT Installer repository branch [DEFAULT main]
    --dev-test   Sets TEST Envar to 1
    --dry-run    Sets up dependencies but exits before running any playbooks
    --ip-addr    Explicitly set IP address (when http://ifconfig.me/ip is wrong)
USAGE_TEXT
  exit
}

###############################################################################
# Cleanup here
###############################################################################
function cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  if [[ -n $NEEDRESTART ]]; then
    cp $HOME/nr-conf-temp $NEEDRESTART
  fi
}

###############################################################################
# Echo a message
###############################################################################
function msg() {
  echo >&2 -e "${1-}"
}

###############################################################################
# Exit gracefully
###############################################################################
function die() {
  local msg=$1
  local code=${2-1}
  msg "$msg"
  [[ $code -eq 0 ]] || echo -e "Exiting. Installation NOT successful."
  exit "$code"
}

###############################################################################
# Parse parameters
###############################################################################
function parse_params() {
  APT_VERBOSITY="-qq"

  while true; do
    case "${1-}" in
    --help | -h)
      usage
      exit 0
      shift
      ;;
    --verbose | -v)
      echo "Verbose output"
      set -x
      NO_COLOR=1
      GIT_TRACE=true
      GIT_CURL_VERBOSE=true
      GIT_SSH_COMMAND="ssh -vvv"
      unset APT_VERBOSITY
      ANSIBLE_VERBOSITY="-vvvvv"
      shift
      ;;
    --check | -c)
      CHECK=1
      shift
      ;;
    --core)
      CORE=1
      shift
      ;;
    --stable | -s)
      INSTALL_TYPE="stable"
      shift
      ;;
    --latest)
      INSTALL_TYPE="latest"
      shift
      ;;
    --legacy | -l)
      INSTALL_TYPE="legacy"
      shift
      ;;
    -B)
      echo "${RED}${hsep}${hsep}${hsep}"
      echo -e "This option is not supported for public use.\n\
      It will alter the version of this installer, which means:\n\
      1. it may make breaking system alterations\n\
      2. use at your own risk\n\
      It is highly recommended that you do not continue\n\
      unless you've selected this option for a specific reason"
      echo "${hsep}${hsep}${hsep}${NOFORMAT}"
      CBRANCH=$2
      shift 2
      ;;
    --repo)
      REPO=$2
      shift 2
      if [[ -d ~/FreeTAKHub-Installation ]]; then
        rm -rf ~/FreeTAKHub-Installation
      fi
      ;;
    --branch)
      BRANCH=$2
      shift 2
      ;;
    --dev-test)
      TEST=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --ip-addr)
      FTS_IP_CUSTOM=$2
      shift 2
      echo "Using the IP of ${FTS_IP_CUSTOM}"
      ;;
    --no-color)
      NO_COLOR=1
      shift
      ;;
    -?*)
      die "ERROR: unknown option $1"
      ;;
    *)
      break
      ;;
    esac
  done
}

###############################################################################
# Update variables from defaults, user inputs or implied values
###############################################################################
function set_versions() {
  case $INSTALL_TYPE in
  latest)
    export PY3_VER=$PY3_VER_STABLE
    export FTS_VERSION=$LATEST_FTS_VERSION
    export CFG_RPATH="core/configuration"
    ;;
  legacy)
    export PY3_VER=$PY3_VER_LEGACY
    export FTS_VERSION=$LEGACY_FTS_VERSION
    export CFG_RPATH="controllers/configuration"
    ;;
  stable)
    export PY3_VER=$PY3_VER_STABLE
    export FTS_VERSION=$STABLE_FTS_VERSION
    export CFG_RPATH="core/configuration"
    ;;
  *)
    die "Unsupported install type: $INSTALL_TYPE"
    ;;
  esac
}

###############################################################################
# Check if script was ran as root
###############################################################################
function check_root() {
  echo -e -n "${BLUE}Checking if this script is running as root...${NOFORMAT}"
  if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}ERROR${NOFORMAT}"
    die "This script requires running as root. Use sudo before the command."
  else
    echo -e "${GREEN}Success!${NOFORMAT}"
  fi
}

###############################################################################
# Check for supported operating system and set codename
###############################################################################
function check_os() {
  which apt-get >/dev/null
  if [[ $? -ne 0 ]]; then
    die "Could not locate apt... this installation method will not work"
  fi

  echo -e -n "${BLUE}Checking system information...${NOFORMAT}"

  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=${NAME:-unknown}
    VER=${VERSION_ID:-unknown}
    CODENAME=${VERSION_CODENAME}
  elif type lsb_release >/dev/null 2>&1; then
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
  else
    OS=$(uname -s)
    VER=$(uname -r)
  fi

  echo -e "${GREEN}Success!${NOFORMAT}"
  echo -e "This machine is currently running: ${GREEN}${OS} ${VER}${NOFORMAT}"
  echo -e "Selected install type is: ${GREEN}${INSTALL_TYPE}${NOFORMAT}"

  # For Debian compatibility
  if [[ "${OS}" == "Debian GNU/Linux" ]]; then
    case "${VER}" in
    "12")
      export CODENAME="bookworm"
      ;;
    "11")
      export CODENAME="bullseye"
      ;;
    "10")
      export CODENAME="buster"
      ;;
    *)
      echo -e "${YELLOW}WARNING: Unknown Debian version${NOFORMAT}"
      ;;
    esac
  fi
}

###############################################################################
# Download dependencies
###############################################################################
function download_dependencies() {
  echo -e "${BLUE}Downloading dependencies...${NOFORMAT}"

  x=$(find /etc/apt/apt.conf.d -name "*needrestart*")
  if [[ -f $x ]]; then
    NEEDRESTART=$x
    mv $x $HOME/nr-conf-temp
  fi

  x="pkg inst"
  for y in $x; do
    z=$(find /usr/lib -name apt_${y}.so)
    if [[ -z $z ]]; then
      z=$(find /usr/lib -name "apt_${y}.cpython*.so")
      ln -sf $z $(dirname $z)/apt_${y}.so
    fi
  done

  # Install required packages
  apt-get update
  apt-get -y install software-properties-common gnupg2 curl

  # Add Ansible repository and install
  echo "deb http://ppa.launchpad.net/ansible/ansible/ubuntu focal main" >/etc/apt/sources.list.d/ansible.list
  apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 93C4A3FD7BB9C367

  apt-get update
  apt-get -y ${APT_VERBOSITY--qq} install ansible
  apt-get -y ${APT_VERBOSITY--qq} install git
}

###############################################################################
# Install Python environment
###############################################################################
function install_python_environment() {
  apt-get update
  apt-get install -y python3-pip python3-setuptools
  apt-get install -y python${PY3_VER}-dev python${PY3_VER}-venv libpython${PY3_VER}-dev

  /usr/bin/python${PY3_VER} -m venv ${FTS_VENV}
  source ${FTS_VENV}/bin/activate

  python3 -m pip install --upgrade pip
  python3 -m pip install --force-reinstall jinja2
  python3 -m pip install --force-reinstall pyyaml
  python3 -m pip install --force-reinstall psutil

  deactivate
}

###############################################################################
# Handle git repository
###############################################################################
function handle_git_repository() {
  echo -e -n "${BLUE}Checking for FreeTAKHub-Installation in home directory..."
  cd ~

  [[ -n $CBRANCH ]] && BRANCH=$CBRANCH
  if [[ ! -d ~/FreeTAKHub-Installation ]]; then
    echo -e "local working git tree NOT FOUND"
    echo -e "Cloning the FreeTAKHub-Installation repository...${NOFORMAT}"
    git clone --branch "${BRANCH}" ${REPO} ~/FreeTAKHub-Installation
    cd ~/FreeTAKHub-Installation
  else
    echo -e "FOUND"
    cd ~/FreeTAKHub-Installation
    echo -e "Pulling latest from the FreeTAKHub-Installation repository...${NOFORMAT}"
    git pull
    git checkout "${BRANCH}"
  fi

  git pull
}

###############################################################################
# Add passwordless Ansible execution
###############################################################################
function add_passwordless_ansible_execution() {
  echo -e "${BLUE}Adding passwordless Ansible execution for the current user...${NOFORMAT}"
  LINE="${USER} ALL=(ALL) NOPASSWD:/usr/bin/ansible-playbook"
  FILE="/etc/sudoers.d/dont-prompt-${USER}-for-sudo-password"
  grep -qF -- "${LINE}" "${FILE}" 2>/dev/null || echo "${LINE}" >"${FILE}"
}

###############################################################################
# Generate public and private keys
###############################################################################
function generate_key_pair() {
  echo -e "${BLUE}Creating public and private keys if non-existent...${NOFORMAT}"
  if [[ ! -e ${HOME}/.ssh/id_rsa.pub ]]; then
    ssh-keygen -t rsa -f "${HOME}/.ssh/id_rsa" -N ""
  fi
}

###############################################################################
# Run Ansible playbook
###############################################################################
function run_playbook() {
  export CODENAME
  export INSTALL_TYPE
  export FTS_VERSION
  env_vars="python3_version=$PY3_VER codename=$CODENAME itype=$INSTALL_TYPE"
  env_vars="$env_vars fts_version=$FTS_VERSION cfg_rpath=$CFG_RPATH fts_venv=${FTS_VENV}"
  [[ -n "${FTS_IP_CUSTOM:-}" ]] && env_vars="$env_vars fts_ip_addr_extra=$FTS_IP_CUSTOM"
  [[ -n "${WEBMAP_FORCE_INSTALL:-}" ]] && env_vars="$env_vars $WEBMAP_FORCE_INSTALL"
  [[ -n "${CORE:-}" ]] && pb=install_mainserver || pb=install_all
  echo -e "${BLUE}Running Ansible Playbook ${GREEN}$pb${BLUE}...${NOFORMAT}"
  ansible-playbook -u root ${pb}.yml \
    --connection=local \
    --inventory localhost, \
    --extra-vars "$env_vars" \
    ${ANSIBLE_VERBOSITY-}
}

###############################################################################
# Main execution
###############################################################################
setup_colors
parse_params "${@}"
set_versions
check_root
check_os
download_dependencies
[[ "$DEFAULT_INSTALL_TYPE" == "$INSTALL_TYPE" ]] && install_python_environment
handle_git_repository
add_passwordless_ansible_execution
generate_key_pair

[[ 0 -eq $DRY_RUN ]] || die "Dry run complete. Not running Ansible" 0
run_playbook
cleanup
