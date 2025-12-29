#!/usr/bin/env bash
# Install prerequisites for just recipes
#
# Usage: ./.just/install-prerequisites.sh
#
# This script checks for required tools (just, gh, shellcheck, markdownlint-cli2, jq)
# and helps install them:
#
# - macOS: Automatically installs missing tools using Homebrew
# - Linux: Displays installation commands for manual execution
# - Other: Shows links to installation documentation
#
# Run multiple times to verify installations completed successfully.

set -euo pipefail # strict mode

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo -e "${MAGENTA}Checking prerequisites for just recipes...${NC}"
echo ""

MISSING=()
INSTALLED=()

# check each prerequisite
if command -v just &> /dev/null; then
    INSTALLED+=("just")
else
    MISSING+=("just")
fi

if command -v gh &> /dev/null; then
    INSTALLED+=("gh")
else
    MISSING+=("gh")
fi

if command -v shellcheck &> /dev/null; then
    INSTALLED+=("shellcheck")
else
    MISSING+=("shellcheck")
fi

if command -v markdownlint-cli2 &> /dev/null; then
    INSTALLED+=("markdownlint-cli2")
else
    MISSING+=("markdownlint-cli2")
fi

if command -v jq &> /dev/null; then
    INSTALLED+=("jq")
else
    MISSING+=("jq")
fi

# report what's already installed
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    echo -e "${GREEN}Already installed:${NC}"
    for tool in "${INSTALLED[@]}"; do
        echo -e "  ${GREEN}✓${NC} $tool"
    done
    echo ""
fi

# if everything is installed, we're done
if [[ ${#MISSING[@]} -eq 0 ]]; then
    echo -e "${GREEN}All prerequisites are installed!${NC}"
    exit 0
fi

# report what's missing
echo -e "${YELLOW}Missing prerequisites:${NC}"
for tool in "${MISSING[@]}"; do
    echo -e "  ${YELLOW}✗${NC} $tool"
done
echo ""

# detect OS and provide installation instructions
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo -e "${BLUE}Detected macOS. Installing with Homebrew...${NC}"
    echo ""

    if ! command -v brew &> /dev/null; then
        echo -e "${RED}Homebrew is not installed!${NC}"
        echo "Install Homebrew first: https://brew.sh"
        exit 1
    fi

    INSTALL_SUCCESS=()
    INSTALL_FAILED=()

    for tool in "${MISSING[@]}"; do
        case "$tool" in
            just)
                echo -e "${CYAN}Installing just...${NC}"
                if brew install just; then
                    INSTALL_SUCCESS+=("just")
                else
                    INSTALL_FAILED+=("just")
                    echo -e "${RED}Failed to install just${NC}"
                fi
                ;;
            gh)
                echo -e "${CYAN}Installing GitHub CLI...${NC}"
                if brew install gh; then
                    INSTALL_SUCCESS+=("gh")
                    echo -e "${YELLOW}Don't forget to authenticate: gh auth login${NC}"
                else
                    INSTALL_FAILED+=("gh")
                    echo -e "${RED}Failed to install gh${NC}"
                fi
                ;;
            shellcheck)
                echo -e "${CYAN}Installing shellcheck...${NC}"
                if brew install shellcheck; then
                    INSTALL_SUCCESS+=("shellcheck")
                else
                    INSTALL_FAILED+=("shellcheck")
                    echo -e "${RED}Failed to install shellcheck${NC}"
                fi
                ;;
            markdownlint-cli2)
                echo -e "${CYAN}Installing markdownlint-cli2...${NC}"
                if ! command -v npm &> /dev/null; then
                    echo -e "${RED}npm is not installed! Install Node.js first.${NC}"
                    echo "Install Node.js: brew install node"
                    INSTALL_FAILED+=("markdownlint-cli2")
                elif npm install -g markdownlint-cli2; then
                    INSTALL_SUCCESS+=("markdownlint-cli2")
                else
                    INSTALL_FAILED+=("markdownlint-cli2")
                    echo -e "${RED}Failed to install markdownlint-cli2${NC}"
                fi
                ;;
            jq)
                echo -e "${CYAN}Installing jq...${NC}"
                if brew install jq; then
                    INSTALL_SUCCESS+=("jq")
                else
                    INSTALL_FAILED+=("jq")
                    echo -e "${RED}Failed to install jq${NC}"
                fi
                ;;
        esac
    done

    echo ""
    if [[ ${#INSTALL_SUCCESS[@]} -gt 0 ]]; then
        echo -e "${GREEN}Successfully installed:${NC}"
        for tool in "${INSTALL_SUCCESS[@]}"; do
            echo -e "  ${GREEN}✓${NC} $tool"
        done
    fi

    if [[ ${#INSTALL_FAILED[@]} -gt 0 ]]; then
        echo ""
        echo -e "${RED}Failed to install:${NC}"
        for tool in "${INSTALL_FAILED[@]}"; do
            echo -e "  ${RED}✗${NC} $tool"
        done
        echo ""
        echo -e "${YELLOW}Run this script again to retry or install manually.${NC}"
        exit 1
    fi

elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo -e "${BLUE}Detected Linux. Showing installation commands...${NC}"
    echo ""

    # detect package manager
    if command -v apt-get &> /dev/null; then
        PKG_MGR="apt-get"
        echo -e "${BLUE}Using apt-get package manager${NC}"
    elif command -v dnf &> /dev/null; then
        PKG_MGR="dnf"
        echo -e "${BLUE}Using dnf package manager${NC}"
    elif command -v pacman &> /dev/null; then
        PKG_MGR="pacman"
        echo -e "${BLUE}Using pacman package manager${NC}"
    else
        echo -e "${YELLOW}Could not detect package manager. Manual installation required.${NC}"
        PKG_MGR="manual"
    fi

    for tool in "${MISSING[@]}"; do
        case "$tool" in
            just)
                if [[ "$PKG_MGR" == "apt-get" ]]; then
                    echo -e "${CYAN}Install just:${NC}"
                    echo "  wget -qO - 'https://proget.makedeb.org/debian-feeds/prebuilt-mpr.pub' | gpg --dearmor | sudo tee /usr/share/keyrings/prebuilt-mpr-archive-keyring.gpg 1> /dev/null"
                    echo "  echo \"deb [arch=all,\$(dpkg --print-architecture) signed-by=/usr/share/keyrings/prebuilt-mpr-archive-keyring.gpg] https://proget.makedeb.org prebuilt-mpr \$(lsb_release -cs)\" | sudo tee /etc/apt/sources.list.d/prebuilt-mpr.list"
                    echo "  sudo apt update && sudo apt install just"
                elif [[ "$PKG_MGR" == "dnf" ]]; then
                    echo -e "${CYAN}Install just:${NC} sudo dnf install just"
                elif [[ "$PKG_MGR" == "pacman" ]]; then
                    echo -e "${CYAN}Install just:${NC} sudo pacman -S just"
                else
                    echo -e "${CYAN}Install just:${NC} See https://github.com/casey/just#installation"
                fi
                ;;
            gh)
                echo -e "${CYAN}Install GitHub CLI:${NC} See https://github.com/cli/cli/blob/trunk/docs/install_linux.md"
                echo -e "${YELLOW}Don't forget to authenticate: gh auth login${NC}"
                ;;
            shellcheck)
                if [[ "$PKG_MGR" == "apt-get" ]]; then
                    echo -e "${CYAN}Install shellcheck:${NC} sudo apt-get install shellcheck"
                elif [[ "$PKG_MGR" == "dnf" ]]; then
                    echo -e "${CYAN}Install shellcheck:${NC} sudo dnf install shellcheck"
                elif [[ "$PKG_MGR" == "pacman" ]]; then
                    echo -e "${CYAN}Install shellcheck:${NC} sudo pacman -S shellcheck"
                fi
                ;;
            markdownlint-cli2)
                echo -e "${CYAN}Install markdownlint-cli2:${NC} npm install -g markdownlint-cli2"
                echo -e "${YELLOW}(Requires Node.js/npm)${NC}"
                ;;
            jq)
                if [[ "$PKG_MGR" == "apt-get" ]]; then
                    echo -e "${CYAN}Install jq:${NC} sudo apt-get install jq"
                elif [[ "$PKG_MGR" == "dnf" ]]; then
                    echo -e "${CYAN}Install jq:${NC} sudo dnf install jq"
                elif [[ "$PKG_MGR" == "pacman" ]]; then
                    echo -e "${CYAN}Install jq:${NC} sudo pacman -S jq"
                fi
                ;;
        esac
    done

    echo ""
    echo -e "${YELLOW}Note: Commands shown above for manual execution.${NC}"
    echo -e "${YELLOW}Run this script again after installing to verify.${NC}"

else
    echo -e "${YELLOW}Unsupported OS: $OSTYPE${NC}"
    echo -e "${YELLOW}Please install these tools manually:${NC}"
    for tool in "${MISSING[@]}"; do
        echo "  - $tool"
    done
    echo ""
    echo -e "${CYAN}Installation resources:${NC}"
    echo "  just: https://github.com/casey/just#installation"
    echo "  gh: https://cli.github.com/manual/installation"
    echo "  shellcheck: https://github.com/koalaman/shellcheck#installing"
    echo "  markdownlint-cli2: npm install -g markdownlint-cli2"
    echo "  jq: https://stedolan.github.io/jq/download/"
    exit 1
fi

echo ""
echo -e "${GREEN}Installation complete! Run this script again to verify.${NC}"
