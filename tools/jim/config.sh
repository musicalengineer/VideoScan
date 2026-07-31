# Shared defaults for the gofer harness. Sourced by bin/gofer.sh.
# An individual employees/<name>.conf may override any of these.

# Who answers when the engine is run without a name-symlink and without --employee.
DEFAULT_EMPLOYEE="jim"

# Where the local brain is served. Jim's model runs on the M5 Pro MBP, reachable
# over the LAN as ricksm5.local. If you run the engine ON that same machine,
# an employee .conf can override HOST to "localhost".
DEFAULT_HOST="ricksm5.local"
DEFAULT_PORT="11434"
DEFAULT_SCHEME="http"

# Request shaping.
DEFAULT_TEMPERATURE="0.2"
DEFAULT_MAX_TOKENS="2048"
DEFAULT_TIMEOUT="120"

# Qwen3 thinking models emit <think>...</think>; strip it from gofer output by default.
DEFAULT_STRIP_THINK="1"

# Thinking control, sent as the native /api/chat "think" field.
# "" = omit (model default) · "false" = suppress thinking · "true" = force it.
# Gofer tasks are bounded grunt work; employees on qwen3-family brains should
# set THINK="false" in their .conf or the model can spend its whole num_predict
# budget reasoning and return empty content.
DEFAULT_THINK=""
