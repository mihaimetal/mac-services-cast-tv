-- Unsandboxed helper for the "Cast to TV" Service.
-- Safari runs Services inside its sandbox, so the workflow only opens
-- a casttv:// URL; this applet decodes it and runs ~/.local/bin/cast.sh.
on open location this_URL
	set theScheme to "casttv://"
	if this_URL starts with theScheme then
		set b64 to text ((length of theScheme) + 1) thru -1 of this_URL
	else
		set b64 to this_URL
	end if
	set theCmd to "mkdir -p \"$HOME/.local/share\"; " & ¬
		"{ echo \"=== $(date) ===\"; " & ¬
		"URL=$(printf %s " & quoted form of b64 & " | base64 -D); " & ¬
		"echo \"decoded: $URL\"; " & ¬
		"export PATH=\"$HOME/Miniforge3/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"; " & ¬
		"\"$HOME/.local/bin/cast.sh\" \"$URL\"; " & ¬
		"echo \"exit=$?\"; } >> \"$HOME/.local/share/cast.log\" 2>&1"
	do shell script theCmd
	tell me to quit
end open location
