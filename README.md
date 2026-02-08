# TinkerEdit
by SpiderDave

TinkerEdit is a command-line save editor and rebuild tool for Tinkerlands.
It can extract files from a .sav file for editing and then rebuild them.
World save files are located in local user data, for example:
    `C:\Users\<username>\AppData\Local\Tinkerlands\worlds\savegame01\main.sav`
It is strongly recommended you backup all your saves periodically.

## Installation
* Extract the files to a folder
* Open a command prompt in the TinkerEdit main folder and run various commands.

## Usage
```
Usage: TinkerEdit [opts]

Options:
  -x, --extract:filename          extract save file (default: main.sav)
  -b, --build:filename            rebuild save file (default: main_new.sav)
  -l, --level:best|speed          compression level (default: speed)
  -h, --help                      show this help

Examples:
  TinkerEdit -x
  TinkerEdit -x:main.sav
  TinkerEdit -b:main_new.sav --level=speed
```
