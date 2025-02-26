#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <updater>

#define UPDATE_URL "https://raw.githubusercontent.com/maxijabase/sm-bulletin/main/updatefile.txt"
#define CHAT_PREFIX "\x04[Bulletins]\x01"

Database g_Database;
bool g_PlayerSubscribed[MAXPLAYERS + 1];
bool g_BulletinsShown[MAXPLAYERS + 1];
char g_CurrentBulletinId[MAXPLAYERS + 1][16];
bool g_ReadingBulletins[MAXPLAYERS + 1];
bool g_BrowsingHistory[MAXPLAYERS + 1];
int g_HistoryPage[MAXPLAYERS + 1];

public Plugin myinfo = {
  name = "Bulletins", 
  author = "ampere", 
  description = "Database-driven bulletin system with global and optional messages", 
  version = "1.0", 
  url = "github.com/maxijabase"
};

public void OnPluginStart() {
  // Commands
  RegAdminCmd("sm_bulletin", Command_AddBulletin, ADMFLAG_GENERIC, "Add a new bulletin");
  RegConsoleCmd("sm_subscribe", Command_Subscribe, "Subscribe to optional bulletins");
  RegConsoleCmd("sm_unsubscribe", Command_Unsubscribe, "Unsubscribe from optional bulletins");
  RegConsoleCmd("sm_bulletins", Command_ViewBulletins, "View all bulletins history");

  // Hook inventory event
  HookEvent("post_inventory_application", Event_PostInventoryApplication);
  
  // Database connection
  Database.Connect(Database_OnConnect, "bulletins");
  
  // Load all clients' subscription status
  for (int i = 1; i <= MaxClients; i++) {
    if (IsClientInGame(i) && !IsFakeClient(i)) {
      LoadClientSubscription(i);
    }
  }
  
  // Updater
  if (LibraryExists("updater")) {
    Updater_AddPlugin(UPDATE_URL);
  }
}

public void OnLibraryAdded(const char[] name) {
  if (StrEqual(name, "updater")) {
    Updater_AddPlugin(UPDATE_URL);
  }
}

public void OnClientConnected(int client) {
  g_PlayerSubscribed[client] = true;
  g_BulletinsShown[client] = false;
  g_CurrentBulletinId[client][0] = '\0';
  g_ReadingBulletins[client] = false;
  g_BrowsingHistory[client] = false;
  g_HistoryPage[client] = 0;
}

public void OnClientDisconnect(int client) {
  g_BulletinsShown[client] = false; // Reset for next connection
}

public Action Event_PostInventoryApplication(Event event, const char[] name, bool dontBroadcast) {
  int client = GetClientOfUserId(event.GetInt("userid"));
  
  if (client > 0 && !g_BulletinsShown[client] && !IsFakeClient(client)) {
    g_BulletinsShown[client] = true;
    ShowPendingBulletins(client);
  }
  
  return Plugin_Continue;
}

public void OnClientAuthorized(int client, const char[] auth) {
  if (!IsFakeClient(client)) {
    LoadClientSubscription(client);
  }
}

void Database_OnConnect(Database db, const char[] error, any data) {
  if (db == null) {
    LogError("Database connection failed: %s", error);
    return;
  }
  
  g_Database = db;
  
  // Create tables if they don't exist
  char query[1024];
  Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS bulletins_posts (\
        id INTEGER PRIMARY KEY AUTO_INCREMENT, \
        message VARCHAR(255) NOT NULL, \
        type ENUM('global', 'optional') NOT NULL, \
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)");
  g_Database.Query(Database_ErrorCheck, query);
  
  Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS bulletins_reads (\
        bulletin_id INTEGER, \
        steam_id VARCHAR(32), \
        read_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, \
        PRIMARY KEY (bulletin_id, steam_id))");
  g_Database.Query(Database_ErrorCheck, query);
  
  Format(query, sizeof(query), "CREATE TABLE IF NOT EXISTS bulletins_subs (\
        steam_id VARCHAR(32) PRIMARY KEY, \
        subscribed BOOLEAN DEFAULT 1)");
  g_Database.Query(Database_ErrorCheck, query);
}

void LoadClientSubscription(int client) {
  if (g_Database == null)return;
  
  char steam_id[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id)))return;
  
  char query[256];
  Format(query, sizeof(query), "SELECT subscribed FROM bulletins_subs WHERE steam_id = '%s'", steam_id);
  g_Database.Query(Query_LoadSubscription, query, GetClientUserId(client));
}

public void Query_LoadSubscription(Database db, DBResultSet results, const char[] error, any data) {
  if (error[0]) {
    LogError("Failed to load subscription: %s", error);
    return;
  }
  
  int client = GetClientOfUserId(data);
  if (client == 0)return;
  
  if (results.FetchRow()) {
    g_PlayerSubscribed[client] = results.FetchInt(0) == 1;
  } else {
    // Insert default subscription status
    char steam_id[32];
    if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id)))return;
    
    char query[256];
    Format(query, sizeof(query), "INSERT INTO bulletins_subs (steam_id, subscribed) VALUES ('%s', 1)", steam_id);
    g_Database.Query(Database_ErrorCheck, query);
    
    g_PlayerSubscribed[client] = true;
  }
}

void ShowPendingBulletins(int client) {
  if (g_Database == null) return;
  
  char steam_id[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id))) return;
  
  char query[512];
  Format(query, sizeof(query), "SELECT a.id, a.message, a.type, DATE_FORMAT(a.created_at, '%%d/%%m/%%y %%H:%%i') as date FROM bulletins_posts a \
        LEFT JOIN bulletins_reads ar ON a.id = ar.bulletin_id AND ar.steam_id = '%s' \
        WHERE ar.bulletin_id IS NULL AND (a.type = 'global' OR (a.type = 'optional' AND EXISTS \
        (SELECT 1 FROM bulletins_subs WHERE steam_id = '%s' AND subscribed = 1)))", 
        steam_id, steam_id);
  
  g_Database.Query(Query_ShowBulletins, query, GetClientUserId(client));
}

public void Query_ShowBulletins(Database db, DBResultSet results, const char[] error, any data) {
  if (error[0]) {
    LogError("Failed to load bulletins: %s", error);
    return;
  }
  
  int client = GetClientOfUserId(data);
  if (client == 0) return;
  
  if (!results.RowCount) {
    // Only show the "no more bulletins" message if they were actively reading
    if (g_ReadingBulletins[client]) {
      PrintToChat(client, "%s No more pending bulletins!", CHAT_PREFIX);
      g_ReadingBulletins[client] = false;
    }
    return;
  }
  
  // Get the first unread bulletin
  results.FetchRow();
  char id[16], message[1024], type[16], date[32];
  results.FetchString(0, id, sizeof(id));
  results.FetchString(1, message, sizeof(message));
  results.FetchString(2, type, sizeof(type));
  results.FetchString(3, date, sizeof(date));
  
  // Store the current bulletin ID
  strcopy(g_CurrentBulletinId[client], sizeof(g_CurrentBulletinId[]), id);
  
  Panel panel = new Panel();
  
  char title[128];
  char formattedType[32];
  FormatBulletinType(type, formattedType, sizeof(formattedType));
  
  Format(title, sizeof(title), "New %s Bulletin (%s)", formattedType, date);
  panel.SetTitle(title);
  
  // Add empty line after title
  panel.DrawText(" ");
  
  // Add message with word wrap
  panel.DrawText(message);
  
  // Add empty line after message
  panel.DrawText(" ");
  
  // Draw the navigation items
  panel.DrawItem("Next", ITEMDRAW_CONTROL);
  panel.DrawItem("Exit", ITEMDRAW_CONTROL);
  
  panel.Send(client, PanelHandler_Bulletin, MENU_TIME_FOREVER);
}

public int PanelHandler_Bulletin(Menu menu, MenuAction action, int param1, int param2) {
  switch (action) {
    case MenuAction_Select: {
      // Validate we have a bulletin ID
      if (g_CurrentBulletinId[param1][0] == '\0') return 0;
      
      // If not browsing history, mark as read
      if (!g_BrowsingHistory[param1]) {
        char steam_id[32];
        if (!GetClientAuthId(param1, AuthId_Steam2, steam_id, sizeof(steam_id)))
          return 0;
        
        // Escape the steam ID
        char escaped_steam_id[64];
        g_Database.Escape(steam_id, escaped_steam_id, sizeof(escaped_steam_id));
        
        // Mark as read
        char query[256];
        Format(query, sizeof(query), "INSERT INTO bulletins_reads (bulletin_id, steam_id) VALUES ('%s', '%s')", 
          g_CurrentBulletinId[param1], escaped_steam_id);
        g_Database.Query(Database_ErrorCheck, query);
      }
      
      // If they pressed 1 (Next)
      if (param2 == 1) {
        if (g_BrowsingHistory[param1]) {
          // Increment the page counter for history browsing
          g_HistoryPage[param1]++;
          ShowBulletinHistory(param1);
        } else {
          // Continue with normal unread bulletins
          g_ReadingBulletins[param1] = true;
          ShowPendingBulletins(param1);
        }
      } else {
        // Exit
        g_ReadingBulletins[param1] = false;
        g_BrowsingHistory[param1] = false;
      }
      
      // Clear the current bulletin ID
      g_CurrentBulletinId[param1][0] = '\0';
    }
    case MenuAction_Cancel: {
      // If not browsing history, mark as read on cancel too
      if (!g_BrowsingHistory[param1] && g_CurrentBulletinId[param1][0] != '\0') {
        char steam_id[32];
        if (GetClientAuthId(param1, AuthId_Steam2, steam_id, sizeof(steam_id))) {
          char escaped_steam_id[64];
          g_Database.Escape(steam_id, escaped_steam_id, sizeof(escaped_steam_id));
          
          char query[256];
          Format(query, sizeof(query), "INSERT INTO bulletins_reads (bulletin_id, steam_id) VALUES ('%s', '%s')", 
            g_CurrentBulletinId[param1], escaped_steam_id);
          g_Database.Query(Database_ErrorCheck, query);
        }
      }
      
      // Clear the current bulletin ID and flags
      g_CurrentBulletinId[param1][0] = '\0';
      g_ReadingBulletins[param1] = false;
      g_BrowsingHistory[param1] = false;
    }
    case MenuAction_End: {
      delete view_as<Panel>(menu);
    }
  }
  return 0;
}

public Action Command_AddBulletin(int client, int args) {
  if (args < 1) {
    ReplyToCommand(client, "%s Usage: sm_bulletin <type: global|optional> <message>", CHAT_PREFIX);
    return Plugin_Handled;
  }
  
  char type[16];
  GetCmdArg(1, type, sizeof(type));
  
  if (strcmp(type, "global", false) != 0 && strcmp(type, "optional", false) != 0) {
    ReplyToCommand(client, "%s Invalid bulletin type. Use 'global' or 'optional'.", CHAT_PREFIX);
    return Plugin_Handled;
  }
  
  char message[1024];
  GetCmdArgString(message, sizeof(message));
  
  // Remove the type argument from the message
  int typeLen = strlen(type) + 1; // +1 for the space
  int messageLen = strlen(message);
  if (messageLen <= typeLen) {
    ReplyToCommand(client, "%s Please provide a message.", CHAT_PREFIX);
    return Plugin_Handled;
  }
  
  // Trim the type and first space from the message
  char trimmedMessage[1024];
  strcopy(trimmedMessage, sizeof(trimmedMessage), message[typeLen]);
  
  char query[2048];
  Format(query, sizeof(query), "INSERT INTO bulletins_posts (message, type) VALUES ('%s', '%s')", 
    trimmedMessage, type);
  g_Database.Query(Database_ErrorCheck, query);
  
  ReplyToCommand(client, "%s Bulletin added successfully.", CHAT_PREFIX);
  
  // Show the new bulletin to all applicable players
  for (int i = 1; i <= MaxClients; i++) {
    if (IsClientInGame(i) && !IsFakeClient(i)) {
      ShowPendingBulletins(i);
    }
  }
  
  return Plugin_Handled;
}

public Action Command_Subscribe(int client, int args) {
  if (client == 0)return Plugin_Handled;
  
  char steam_id[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id)))return Plugin_Handled;
  
  char escaped_steam_id[64];
  g_Database.Escape(steam_id, escaped_steam_id, sizeof(escaped_steam_id));
  
  char query[256];
  Format(query, sizeof(query), "INSERT INTO bulletins_subs (steam_id, subscribed) VALUES ('%s', 1) \
        ON DUPLICATE KEY UPDATE subscribed = 1", escaped_steam_id);
  g_Database.Query(Database_ErrorCheck, query);
  
  g_PlayerSubscribed[client] = true;
  PrintToChat(client, "%s You are now subscribed to optional bulletins.", CHAT_PREFIX);
  ShowPendingBulletins(client);
  
  return Plugin_Handled;
}

public Action Command_Unsubscribe(int client, int args) {
  if (client == 0)return Plugin_Handled;
  
  char steam_id[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id)))return Plugin_Handled;
  
  char escaped_steam_id[64];
  g_Database.Escape(steam_id, escaped_steam_id, sizeof(escaped_steam_id));
  
  char query[256];
  Format(query, sizeof(query), "INSERT INTO bulletins_subs (steam_id, subscribed) VALUES ('%s', 0) \
        ON DUPLICATE KEY UPDATE subscribed = 0", escaped_steam_id);
  g_Database.Query(Database_ErrorCheck, query);
  
  g_PlayerSubscribed[client] = false;
  PrintToChat(client, "%s You are now unsubscribed from optional bulletins.", CHAT_PREFIX);
  
  return Plugin_Handled;
}

public Action Command_ViewBulletins(int client, int args) {
  if (client == 0) return Plugin_Handled;
  
  // Start browsing history from the first page
  g_BrowsingHistory[client] = true;
  g_HistoryPage[client] = 0;
  g_ReadingBulletins[client] = true;
  ShowBulletinHistory(client);
  
  return Plugin_Handled;
}

void ShowBulletinHistory(int client) {
  if (g_Database == null) return;
  
  char steam_id[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id))) return;
  
  // First, get the total count of bulletins for this player
  char countQuery[512];
  Format(countQuery, sizeof(countQuery), "SELECT COUNT(*) FROM bulletins_posts b \
        WHERE (b.type = 'global' OR (b.type = 'optional' AND EXISTS \
        (SELECT 1 FROM bulletins_subs WHERE steam_id = '%s' AND subscribed = 1)))", 
    steam_id);
  
  g_Database.Query(Query_GetBulletinCount, countQuery, GetClientUserId(client));
}

public void Query_GetBulletinCount(Database db, DBResultSet results, const char[] error, any data) {
  if (error[0]) {
    LogError("Failed to get bulletin count: %s", error);
    return;
  }
  
  int client = GetClientOfUserId(data);
  if (client == 0) return;
  
  if (!results.FetchRow()) {
    PrintToChat(client, "%s Error retrieving bulletins.", CHAT_PREFIX);
    g_ReadingBulletins[client] = false;
    g_BrowsingHistory[client] = false;
    return;
  }
  
  int totalBulletins = results.FetchInt(0);
  
  if (totalBulletins == 0) {
    PrintToChat(client, "%s No bulletins found!", CHAT_PREFIX);
    g_ReadingBulletins[client] = false;
    g_BrowsingHistory[client] = false;
    return;
  }
  
  // If we've gone past the end, loop back to the beginning
  if (g_HistoryPage[client] >= totalBulletins) {
    g_HistoryPage[client] = 0;
  }
  
  // Now get the specific bulletin at the current page index
  char steam_id[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id))) return;
  
  char query[512];
  Format(query, sizeof(query), "SELECT b.id, b.message, b.type, DATE_FORMAT(b.created_at, '%%d/%%m/%%y %%H:%%i') as date, \
        CASE WHEN br.bulletin_id IS NULL THEN 0 ELSE 1 END as is_read \
        FROM bulletins_posts b \
        LEFT JOIN bulletins_reads br ON b.id = br.bulletin_id AND br.steam_id = '%s' \
        WHERE (b.type = 'global' OR (b.type = 'optional' AND EXISTS \
        (SELECT 1 FROM bulletins_subs WHERE steam_id = '%s' AND subscribed = 1))) \
        ORDER BY b.created_at DESC LIMIT %d, 1", 
        steam_id, steam_id, g_HistoryPage[client]);
  
  // Pass the total bulletin count as part of the data
  DataPack pack = new DataPack();
  pack.WriteCell(GetClientUserId(client));
  pack.WriteCell(totalBulletins);
  g_Database.Query(Query_ShowBulletinHistoryWithCount, query, pack);
}

public void Query_ShowBulletinHistoryWithCount(Database db, DBResultSet results, const char[] error, any data) {
  DataPack pack = view_as<DataPack>(data);
  pack.Reset();
  int userid = pack.ReadCell();
  int totalBulletins = pack.ReadCell();
  delete pack;
  
  if (error[0]) {
    LogError("Failed to load bulletin history: %s", error);
    return;
  }
  
  int client = GetClientOfUserId(userid);
  if (client == 0) return;
  
  if (!results.RowCount) {
    PrintToChat(client, "%s Error retrieving bulletin at index %d.", CHAT_PREFIX, g_HistoryPage[client]);
    g_ReadingBulletins[client] = false;
    g_BrowsingHistory[client] = false;
    return;
  }
  
  // Get the bulletin
  results.FetchRow();
  char id[16], message[1024], type[16], date[32];
  results.FetchString(0, id, sizeof(id));
  results.FetchString(1, message, sizeof(message));
  results.FetchString(2, type, sizeof(type));
  results.FetchString(3, date, sizeof(date));
  bool isRead = results.FetchInt(4) == 1;
  
  // Store the current bulletin ID
  strcopy(g_CurrentBulletinId[client], sizeof(g_CurrentBulletinId[]), id);
  
  Panel panel = new Panel();
  
  char title[128];
  char formattedType[32];
  FormatBulletinType(type, formattedType, sizeof(formattedType));
  
  Format(title, sizeof(title), "%s Bulletin (%s) [%d/%d]%s", 
    formattedType, date, g_HistoryPage[client] + 1, totalBulletins, isRead ? " [Read]" : "");
  panel.SetTitle(title);
  
  // Add empty line after title
  panel.DrawText(" ");
  
  // Add message with word wrap
  panel.DrawText(message);
  
  // Add empty line after message
  panel.DrawText(" ");
  
  // Draw the navigation items
  panel.DrawItem("Next", ITEMDRAW_CONTROL);
  panel.DrawItem("Exit", ITEMDRAW_CONTROL);
  
  panel.Send(client, PanelHandler_Bulletin, MENU_TIME_FOREVER);
}

void Database_ErrorCheck(Database db, DBResultSet results, const char[] error, any data) {
  if (error[0]) {
    LogError("Database error: %s", error);
  }
} 

void FormatBulletinType(const char[] type, char[] buffer, int maxlen) {
  if (strcmp(type, "global", false) == 0) {
    strcopy(buffer, maxlen, "Global");
  } else if (strcmp(type, "optional", false) == 0) {
    strcopy(buffer, maxlen, "Optional");
  } else {
    strcopy(buffer, maxlen, type);
  }
}