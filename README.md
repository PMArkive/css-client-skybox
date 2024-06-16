## source !skybox
- completely rebuilt from a csgo plugin by Deathknife (https://github.com/Deathknife/skybox) to work on the old engine
- uses SQLite to store and load player skyboxes across maps.
- requires connect extension (https://forums.alliedmods.net/showthread.php?t=162489), included in repo.
- still incomplete and only tested on LAN, may be buggy. see todo.
- does not use IP.

## cfg
- `sourcemod/configs/databases.cfg` - update info here.
- `sourcemod/data/sqlite/skybox.sq3` - just upload this default db from this repo. haven't tested if it generates successfully yet on its own.
- `sourcemod/configs/skybox.ini` - add custom skyboxes here and they will automatically load in the list.
- make sure your skyboxes exist in `cstrike/materials/skybox`.
- default setup includes some custom skyboxes

## commands
- sm_sky | !sky
- sm_skybox | !skybox

## instructions
1. choose your skybox with commands
2. reconnect to server

## todo
- more extensive testing for database operations (not complete)
- more extensive testing for client index handling (not complete)
- add map change handling
- edge case testing
