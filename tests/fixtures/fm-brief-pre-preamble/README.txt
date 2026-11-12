Generated brief byte contract before captain preambles

These four fixtures capture the public bin/fm-brief.sh scaffold output from
commit 92ef4fb2e53d5364423abdbc5a9efbc52dbdc437, for repo alpha, using the task
IDs in their filenames and modes no-mistakes, direct-PR, local-only, and --scout.
The historical script was executed, rather than deriving expected output from
the preamble implementation under test.

FM_HOME was an empty isolated home with data/ present; FM_DATA_OVERRIDE and
FM_STATE_OVERRIDE selected that home's data/ and state/. FM_ROOT_OVERRIDE
selected the code root. FM_CLASSIFY_PAUSED_VERB=paused and
FM_IDLE_OPEN_WORK_SECS=600 pinned the configurable prose inputs.
Only the literal home and code-root paths were replaced with @FM_HOME@ and
@FM_ROOT@, respectively. No other bytes, including whitespace, were normalized.

The compatibility test compares absent, empty, and whitespace-only preamble
output against these independent fixtures, so a change shared by all three
cases cannot silently redefine the expected pre-change output.
