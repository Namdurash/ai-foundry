# GLM-5.2 (Zhipu / Z.ai) driven through the claude CLI.
#
# GLM speaks the Anthropic Messages API protocol, so it needs no adapter and no
# set of its own — it reuses the claude set verbatim and differs only in the
# environment below. That reuse is the whole architectural bet, and it is the
# single line AIF_PROFILE_SET="claude".
#
# Chosen over the alternatives because it is the only Chinese model whose vendor
# claims survive independent measurement: Artificial Analysis measured 78 on
# Terminal-Bench v2.1 against a claimed 81, while others land 12 points to 2x
# below their own numbers.

AIF_PROFILE_DESC="GLM-5.2 via Z.ai (Anthropic Messages API)"
AIF_PROFILE_RUNNER="claude"
AIF_PROFILE_SET="claude"

# Read from this variable, exported as that one. The token is never stored by
# aif and never written to a file.
AIF_PROFILE_SECRET_VAR="ZAI_API_KEY"
AIF_PROFILE_SECRET_TARGET="ANTHROPIC_AUTH_TOKEN"

# Give GLM its own config root. Resuming a session across providers currently
# bricks it (claude-code#77512: Z.ai returns call_… ids where srvtoolu_… is
# expected, and every subsequent turn 400s). A separate config dir makes that
# structurally impossible rather than merely discouraged.
AIF_PROFILE_ISOLATE_CONFIG="1"

aif_profile_env() {
  # Three of these are load-bearing in ways that are easy to get wrong:
  #
  #   [1m]  is not decoration. Without it the context window is 200K, not 1M,
  #         and it must be paired with CLAUDE_CODE_AUTO_COMPACT_WINDOW or
  #         claude compacts early regardless.
  #   The server default is GLM-4.7, not 5.2 — omit these and you silently get
  #         the older, weaker model.
  #   HAIKU is the current name for the small-model slot;
  #         ANTHROPIC_SMALL_FAST_MODEL is deprecated.
  cat <<'EOF'
ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2[1m]
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-5.2[1m]
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.7
CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000
API_TIMEOUT_MS=3000000
EOF
}
