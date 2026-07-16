# Claude models via Anthropic, using whatever auth `claude` already has.
#
# Profiles are sourced shell. aif only reads them from trusted directories —
# never from a project — because sourcing a file from a cloned repo would be
# arbitrary code execution. See lib/profile.sh.

AIF_PROFILE_DESC="Claude via Anthropic (uses your existing claude auth)"
AIF_PROFILE_RUNNER="claude"
AIF_PROFILE_SET="claude"

# Nothing to supply: `claude` already holds an OAuth session or an API key.
AIF_PROFILE_SECRET_VAR=""
AIF_PROFILE_SECRET_TARGET=""

# Sessions need no isolation here — this is the provider claude expects.
AIF_PROFILE_ISOLATE_CONFIG="0"

# Print KEY=VALUE lines. A function rather than a map because bash 3.2 has no
# associative arrays — and it turns out better anyway: values can be computed.
aif_profile_env() {
  :
}
