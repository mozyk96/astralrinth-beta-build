#!/usr/bin/env fish
set -l script_dir (path dirname (status filename))
exec bash "$script_dir/install.sh" $argv
