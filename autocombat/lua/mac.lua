-- Morituri Auto Combat, short name:  /lua run mac
-- Starts moriac.lua (same folder) under the script name "mac", so
-- /ac restart and the exit hint use /lua run mac / /lua stop mac.
MORIAC_SCRIPT_NAME = 'mac'
local dir = debug.getinfo(1, 'S').source:match('@?(.*[/\\])') or './'
dofile(dir .. 'moriac.lua')
