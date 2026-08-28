-- Unsandboxed helper for the "Cast to TV" / "Queue on TV" Services.
-- Safari runs Services inside its sandbox, so the workflow only opens
-- a casttv:// URL; this applet decodes it and runs ~/.local/bin/cast.sh.
--
--   casttv://<base64>         play now (legacy)
--   casttv://play/<base64>    play now
--   casttv://queue/<base64>   add to the TV YouTube queue
on open location this_URL
	set theScheme to "casttv://"
	if this_URL starts with theScheme then
		set rest to text ((length of theScheme) + 1) thru -1 of this_URL
	else
		set rest to this_URL
	end if
	set modeFlag to ""
	if rest starts with "queue/" then
		set modeFlag to " --queue"
		set b64 to text 7 thru -1 of rest
	else if rest starts with "play/" then
		set b64 to text 6 thru -1 of rest
	else
		set b64 to rest
	end if
	set theCmd to "mkdir -p \"$HOME/.local/share\"; " & ¬
		"{ echo \"=== $(date) ===\"; " & ¬
		"echo raw: " & quoted form of this_URL & "; " & ¬
		"URL=$(printf %s " & quoted form of b64 & " | base64 -D); " & ¬
		"echo \"decoded: $URL modeFlag=" & modeFlag & "\"; " & ¬
		"export PATH=\"$HOME/Miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"; " & ¬
		"\"$HOME/.local/bin/cast.sh\"" & modeFlag & " \"$URL\"; " & ¬
		"echo \"exit=$?\"; } >> \"$HOME/.local/share/cast.log\" 2>&1"
	do shell script theCmd
	tell me to quit
end open location
