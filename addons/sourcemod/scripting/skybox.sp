#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <clientprefs>
#include <dbi>
#include <connect>

#define DB_NAME "skybox"
#define MAX_STEAM_ID_LENGTH 32
#define MAX_PENDING_QUERIES 64 

ConVar g_cvarSkyName;
Menu g_hMenu;
Database g_hDatabase = null; // initialize to null
bool g_bClientSkyboxApplied[MAXPLAYERS + 1];
char g_ClientSteamID[MAXPLAYERS + 1][MAX_STEAM_ID_LENGTH];
char g_PendingSteamIDs[MAX_PENDING_QUERIES][MAX_STEAM_ID_LENGTH];
int g_NextQueryIndex = 0;
int g_PendingQueryCount = 0;

public void OnPluginStart()
{
    RegConsoleCmd("sm_skybox", Cmd_Skybox, "Choose a skybox!");
    RegConsoleCmd("sm_sky", Cmd_Skybox, "Choose a skybox!");

    g_cvarSkyName = FindConVar("sv_skyname");

    // sourcemod/configs/databases.cfg
    Database.Connect(OnDatabaseConnected, "skybox");
}

//connect ext
public bool OnClientPreConnectEx(const char[] name, char password[255], const char[] ip, const char[] steamID, char rejectReason[255])
{
    // find an available slot in the g_ClientSteamID array
    int clientIndex = -1;
    for (int i = 0; i < MAXPLAYERS + 1; i++)
    {
        if (g_ClientSteamID[i][0] == '\0')
        {
            clientIndex = i;
            break;
        }
    }

    if (clientIndex != -1)
    {
        // store the Steam ID in the available slot
        strcopy(g_ClientSteamID[clientIndex], sizeof(g_ClientSteamID[]), steamID);
    }
    else
    {
        LogError("Failed to store Steam ID for client. No available slots.");
    }

    return true;
}

public void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Failed to connect to the SQLite database: %s. Retrying in 5 seconds...", error);
        // retry the connection after 5 seconds
        CreateTimer(5.0, Timer_RetryDatabaseConnection);
    }
    else
    {
        g_hDatabase = db; // successfully set the global database handle
        PrintToServer("Successfully connected to the SQLite database.");

        // create the table if it does not exist.. fix this later, use default sq3 for now
        g_hDatabase.Query(OnTableCreated, "CREATE TABLE IF NOT EXISTS skyboxes (steam_id TEXT, map_name TEXT, skybox_name TEXT, PRIMARY KEY (steam_id, map_name));");

        // now process any clients that are already connected.. TODO: handle this better
        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsValidClient(client))
            {
                LoadClientSkyboxBySteamID(g_ClientSteamID[client]);
            }
        }
    }
}

public Action Timer_RetryDatabaseConnection(Handle timer, any data)
{
    // attempt to reconnect to the database
    PrintToServer("Retrying database connection...");
    Database.Connect(OnDatabaseConnected, DB_NAME);
    return Plugin_Handled;
}

public void OnTableCreated(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        SetFailState("Failed to create the skyboxes table: %s", error);
    }
}

public void OnMapStart()
{
    // create the menu
    g_hMenu = new Menu(Handler_SkyboxMenu);
    g_hMenu.SetTitle("Choose a skybox!");

    LoadSkybox(); // Load file
}

public void OnMapEnd()
{
    // delete menu handle to free resources
    delete g_hMenu;

    //TODO: handle map changes
}

public bool OnClientConnect(int client)
{
    // initialize the skybox status for the client
    g_bClientSkyboxApplied[client] = false;

    // check if the database is connected before attempting to load the client skybox
    if (g_hDatabase != null)
    {
        LoadClientSkyboxBySteamID(g_ClientSteamID[client]);
    }
    else
    {
        LogError("Database handle is invalid or client is a bot. Cannot load skybox for Steam ID %s.", g_ClientSteamID[client]);
    }
    return true;
}

public void OnClientDisconnect(int client)
{
    if (IsValidClient(client))
    {
        g_bClientSkyboxApplied[client] = false;
        g_ClientSteamID[client][0] = '\0'; // clear the Steam ID for the disconnected client
    }
}

/*
public bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && !IsFakeClient(client);
}

this will spam your server with the following errors:
[SM] Exception reported: Client is not connected
[SM] Call stack trace:
[SM] IsFakeClient
*/

// so instead we do
public bool IsValidClient(int client)
{
    if (client > 0 && client <= MaxClients)
    {
        if (IsClientConnected(client)) 
        {
            return !IsFakeClient(client);
        }
        else
        {
            return false;
        }
    }
    return false;
}

public void LoadClientSkyboxBySteamID(const char[] steamId)
{
    // check if the database handle is valid before making the query
    if (g_hDatabase == null)
    {
        LogError("Database handle is invalid. Cannot load skybox for Steam ID %s.", steamId);
        return;
    }

    char query[512];
    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));
    Format(query, sizeof(query), "SELECT skybox_name FROM skyboxes WHERE steam_id = '%s' AND map_name = '%s';", steamId, mapName);

    // handle circular buffer for pending queries
    if (g_PendingQueryCount < MAX_PENDING_QUERIES)
    {
        strcopy(g_PendingSteamIDs[g_NextQueryIndex], sizeof(g_PendingSteamIDs[]), steamId);

        // pass the index as the data parameter to the callback
        g_hDatabase.Query(Callback_LoadSkybox, query, g_NextQueryIndex, DBPrio_High);

        // increment and wrap around the query index
        g_NextQueryIndex = (g_NextQueryIndex + 1) % MAX_PENDING_QUERIES;
        g_PendingQueryCount++;
    }
    else
    {
        LogError("Pending query limit reached. Cannot load skybox for Steam ID %s.", steamId);
    }
}

public void Callback_LoadSkybox(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Failed to load skybox: %s", error);
        g_PendingQueryCount--; // decrement pending count even if it failed
        return;
    }

    // retrieve the steamId from the global array using the index
    int queryIndex = data;
    char steamId[MAX_STEAM_ID_LENGTH];
    strcopy(steamId, sizeof(steamId), g_PendingSteamIDs[queryIndex]);

    // check if the results contain any rows
    if (!results.FetchRow())
    {
        // no results found, use the default skybox
        char defaultSkybox[32];
        g_cvarSkyName.GetString(defaultSkybox, sizeof(defaultSkybox));
        // set skybox for all connected clients
        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsValidClient(client))
            {
                SetSkybox(client, defaultSkybox);
            }
        }
        g_PendingQueryCount--; // Decrement pending count
        return;
    }

    // fetch the skybox name from the results
    char skybox[64];
    results.FetchString(0, skybox, sizeof(skybox));

    // set the skybox for all clients with the same Steam ID
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsValidClient(client) && StrEqual(g_ClientSteamID[client], steamId))
        {
            SetSkybox(client, skybox);
        }
    }
    g_PendingQueryCount--; // decrement pending count after processing
}

public void SetSkybox(int client, const char[] skybox)
{
    if (!IsValidClient(client))
    {
        LogError("Invalid client %d, cannot set skybox.", client);
        return;
    }

    // send sv_skyname to client
    SendConVarValue(client, g_cvarSkyName, skybox);
    PrintToServer("[SKYBOX] Set skybox for client %d: %s", client, skybox);

    // save to SQLite.. TODO: do this somewhere else
    if (g_hDatabase != null) // Ensure database handle is valid
    {
        char query[256];
        char mapName[64];
        GetCurrentMap(mapName, sizeof(mapName));
        Format(query, sizeof(query), "INSERT OR REPLACE INTO skyboxes (steam_id, map_name, skybox_name) VALUES ('%s', '%s', '%s');", g_ClientSteamID[client], mapName, skybox);
        g_hDatabase.Query(OnSkyboxSaved, query);
    }
    else
    {
        LogError("Cannot save skybox for client %d: Database handle is invalid.", client);
    }
}

public void OnSkyboxSaved(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Failed to save skybox: %s", error);
    }
}

public void LoadSkybox()
{
    // create keyvalues
    KeyValues kv = new KeyValues("skybox");

    // parse from config file
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/skybox.ini");
    kv.ImportFromFile(path);

    // go to top node
    kv.Rewind();

    // loop through keyvalues and add to the menu
    char sPath[64];
    char name[32];

    int iSkyboxes = 0;
    if (kv.GotoFirstSubKey())
    {
        do
        {
            // get path & name
            kv.GetString("path", sPath, sizeof(sPath));
            kv.GetString("name", name, sizeof(name));

            // add to menu
            g_hMenu.AddItem(sPath, name);

            iSkyboxes++;

        } while (kv.GotoNextKey());
    }

    // print to server
    PrintToServer("[SKYBOX] Loaded %i Skyboxes!", iSkyboxes);

    // close handle
    delete kv;
}

public Action Cmd_Skybox(int client, int argc)
{
    if (IsValidClient(client))
    {
        g_hMenu.Display(client, MENU_TIME_FOREVER);
    }
    return Plugin_Handled;
}

public int Handler_SkyboxMenu(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_Select)
    {
        if (IsValidClient(client))
        {
            // retrieve the skybox
            char info[64];
            menu.GetItem(param2, info, sizeof(info));

            // set skybox for client
            SetSkybox(client, info);
        }
    }
}
