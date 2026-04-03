// CUE schema for .repo.toml validation
// Validates the structure and types of the repository configuration file

package repo

// About section contains metadata about the repository
about: {
	// Human-readable description of the repository
	description: string & !=""

	// GitHub topics for repository categorization
	topics?: [...string] & [string, ...string]

	// SPDX license identifier
	license?: string & !=""
}

// URLs section contains repository access URLs
urls?: {
	// Git SSH URL for repository access
	git_ssh?: string & =~"^git@github\\.com:[^/]+/.+\\.git$"

	// Web URL for repository viewing
	web_url?: string & =~"^https://github\\.com/[^/]+/.+$"
}

// Flags section contains boolean feature flags
flags?: {
	// Enable Claude AI integration
	claude?: bool

	// Enable Claude code review
	"claude-review"?: bool

	// Enable GitHub Copilot code review
	"copilot-review"?: bool

	// Enable standard release workflow
	"standard-release"?: bool

	// Allow additional custom flags
	...
}
