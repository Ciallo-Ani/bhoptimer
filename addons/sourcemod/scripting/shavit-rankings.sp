/*
 * shavit's Timer - Rankings
 * by: shavit
 *
 * This file is part of shavit's Timer.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
*/

// Design idea:
// Rank 1 per map/style/track gets ((points per tier * tier) * 1.5) + (rank 1 time in seconds / 15.0) points.
// Records below rank 1 get points% relative to their time in comparison to rank 1.
//
// Bonus track gets a 0.25* final multiplier for points and is treated as tier 1.
//
// Points for all styles are combined to promote competitive and fair gameplay.
// A player that gets good times at all styles should be ranked high.
//
// Total player points are weighted in the following way: (descending sort of points)
// points[0] * 0.975^0 + points[1] * 0.975^1 + points[2] * 0.975^2 + ... + points[n] * 0.975^(n-1)
//
// The ranking leaderboard will be calculated upon: map start.
// Points are calculated per-player upon: connection/map.
// Points are calculated per-map upon: map start, map end, tier changes.
// Rankings leaderboard is re-calculated once per map change.
// A command will be supplied to recalculate all of the above.
//
// Heavily inspired by pp (performance points) from osu!, written by Tom94. https://github.com/ppy/osu-performance

#include <sourcemod>

#undef REQUIRE_PLUGIN
#include <shavit>

#pragma newdecls required
#pragma semicolon 1

// uncomment when done
// #define DEBUG

char gS_MySQLPrefix[32];
Database gH_SQL = null;	

bool gB_Stats = false;
bool gB_Late = false;

int gI_Tier = 1; // No floating numbers for tiers, sorry.

char gS_Map[160];

int gI_ValidMaps = 0;
ArrayList gA_ValidMaps = null;
StringMap gA_MapTiers = null;

ConVar gCV_PointsPerTier = null;
float gF_PointsPerTier = 50.0;

int gI_Rank[MAXPLAYERS+1];
float gF_Points[MAXPLAYERS+1];

int gI_RankedPlayers = 0;
Menu gH_Top100Menu = null;

Handle gH_Forwards_OnTierAssigned = null;

// Timer settings.
char gS_ChatStrings[CHATSETTINGS_SIZE][128];
char gS_StyleNames[STYLE_LIMIT][64];
char gS_TrackNames[TRACKS_SIZE][32];

any gA_StyleSettings[STYLE_LIMIT][STYLESETTINGS_SIZE];
int gI_Styles = 0;

public Plugin myinfo =
{
	name = "[shavit] Rankings",
	author = "shavit",
	description = "A fair and competitive ranking system for shavit's bhoptimer.",
	version = SHAVIT_VERSION,
	url = "https://github.com/shavitush/bhoptimer"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("Shavit_GetMapTier", Native_GetMapTier);
	CreateNative("Shavit_GetMapTiers", Native_GetMapTiers);
	CreateNative("Shavit_GetPoints", Native_GetPoints);
	CreateNative("Shavit_GetRank", Native_GetRank);
	CreateNative("Shavit_GetRankedPlayers", Native_GetRankedPlayers);
	CreateNative("Shavit_Rankings_DeleteMap", Native_Rankings_DeleteMap);

	RegPluginLibrary("shavit-rankings");

	gB_Late = late;

	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	if(!LibraryExists("shavit-wr"))
	{
		SetFailState("shavit-wr is required for the plugin to work.");
	}

	if(gH_SQL == null)
	{
		Shavit_OnDatabaseLoaded();
	}

	for(int i = 0; i < TRACKS_SIZE; i++)
	{
		GetTrackName(LANG_SERVER, i, gS_TrackNames[i], 32);
	}
}

public void OnPluginStart()
{
	gH_Forwards_OnTierAssigned = CreateGlobalForward("Shavit_OnTierAssigned", ET_Event, Param_String, Param_Cell);

	RegConsoleCmd("sm_tier", Command_Tier, "Prints the map's tier to chat.");
	RegConsoleCmd("sm_maptier", Command_Tier, "Prints the map's tier to chat. (sm_tier alias)");

	RegConsoleCmd("sm_rank", Command_Rank, "Show your or someone else's rank. Usage: sm_rank [name]");
	RegConsoleCmd("sm_top", Command_Top, "Show the top 100 players."); // The rewrite of rankings will not have the ability to show over 100 entries. Dynamic fetching can be exploited and overload the database.

	RegAdminCmd("sm_settier", Command_SetTier, ADMFLAG_RCON, "Change the map's tier. Usage: sm_settier <tier>");
	RegAdminCmd("sm_setmaptier", Command_SetTier, ADMFLAG_RCON, "Change the map's tier. Usage: sm_setmaptier <tier> (sm_settier alias)");

	RegAdminCmd("sm_recalcmap", Command_RecalcMap, ADMFLAG_RCON, "Recalculate the current map's records' points.");

	RegAdminCmd("sm_recalcall", Command_RecalcAll, ADMFLAG_ROOT, "Recalculate the points for every map on the server. Run this after you change the ranking multiplier for a style or after you install the plugin.");

	gCV_PointsPerTier = CreateConVar("shavit_rankings_pointspertier", "50.0", "Base points to use for per-tier scaling.\nRead the design idea to see how it works: https://github.com/shavitush/bhoptimer/issues/465", 0, true, 1.0);
	gCV_PointsPerTier.AddChangeHook(OnConVarChanged);

	AutoExecConfig();

	LoadTranslations("common.phrases");
	LoadTranslations("shavit-common.phrases");
	LoadTranslations("shavit-rankings.phrases");

	// tier cache
	gA_ValidMaps = new ArrayList(128);
	gA_MapTiers = new StringMap();
	
	SQL_SetPrefix();

	if(gB_Late)
	{
		Shavit_OnChatConfigLoaded();
	}
}

public void Shavit_OnChatConfigLoaded()
{
	for(int i = 0; i < CHATSETTINGS_SIZE; i++)
	{
		Shavit_GetChatStrings(i, gS_ChatStrings[i], 128);
	}
}

public void Shavit_OnStyleConfigLoaded(int styles)
{
	if(styles == -1)
	{
		gI_Styles = Shavit_GetStyleCount();
	}

	for(int i = 0; i < gI_Styles; i++)
	{
		Shavit_GetStyleSettings(i, gA_StyleSettings[i]);
		Shavit_GetStyleStrings(i, sStyleName, gS_StyleNames[i], 64);
	}
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "shavit-stats"))
	{
		gB_Stats = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "shavit-stats"))
	{
		gB_Stats = false;
	}
}

public void Shavit_OnDatabaseLoaded()
{
	gH_SQL = Shavit_GetDatabase();
	SetSQLInfo();
}

public Action CheckForSQLInfo(Handle Timer)
{
	return SetSQLInfo();
}

Action SetSQLInfo()
{
	if(gH_SQL == null)
	{
		gH_SQL = Shavit_GetDatabase();

		CreateTimer(0.5, CheckForSQLInfo);
	}

	else
	{
		SQL_DBConnect();

		return Plugin_Stop;
	}

	return Plugin_Continue;
}

void SQL_SetPrefix()
{
	char sFile[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sFile, PLATFORM_MAX_PATH, "configs/shavit-prefix.txt");

	File fFile = OpenFile(sFile, "r");

	if(fFile == null)
	{
		SetFailState("Cannot open \"configs/shavit-prefix.txt\". Make sure this file exists and that the server has read permissions to it.");
	}
	
	char sLine[PLATFORM_MAX_PATH*2];

	while(fFile.ReadLine(sLine, PLATFORM_MAX_PATH*2))
	{
		TrimString(sLine);
		strcopy(gS_MySQLPrefix, 32, sLine);

		break;
	}

	delete fFile;
}

void SQL_DBConnect()
{
	if(gH_SQL != null)
	{
		char sDriver[8];
		gH_SQL.Driver.GetIdentifier(sDriver, 8);

		if(!StrEqual(sDriver, "mysql", false))
		{
			SetFailState("MySQL is the only supported database engine for shavit-rankings.");
		}

		char sQuery[256];
		FormatEx(sQuery, 256, "CREATE TABLE IF NOT EXISTS `%smaptiers` (`map` CHAR(128), `tier` INT NOT NULL DEFAULT 1, PRIMARY KEY (`map`)) ENGINE=INNODB;", gS_MySQLPrefix);

		gH_SQL.Query(SQL_CreateTable_Callback, sQuery, 0);
	}
}

public void SQL_CreateTable_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings) error! Map tiers table creation failed. Reason: %s", error);

		return;
	}

	#if defined DEBUG
	PrintToServer("DEBUG: 0 (SQL_CreateTable_Callback)");
	#endif

	if(gI_Styles == 0)
	{
		Shavit_OnStyleConfigLoaded(-1);
	}

	SQL_LockDatabase(gH_SQL);
	SQL_FastQuery(gH_SQL, "DELIMITER ;;");
	SQL_FastQuery(gH_SQL, "DROP PROCEDURE IF EXISTS UpdateAllPoints;;"); // old (and very slow) deprecated method
	SQL_FastQuery(gH_SQL, "DROP FUNCTION IF EXISTS GetWeightedPoints;;"); // this is here, just in case we ever choose to modify or optimize the calculation
	SQL_FastQuery(gH_SQL, "DROP FUNCTION IF EXISTS GetRecordPoints;;");

	bool bSuccess = true;

	RunLongFastQuery(bSuccess, "CREATE GetWeightedPoints",
		"CREATE FUNCTION GetWeightedPoints(authid CHAR(32)) " ...
		"RETURNS FLOAT " ...
		"READS SQL DATA " ...
		"BEGIN " ...
		"DECLARE p FLOAT; " ...
		"DECLARE total FLOAT DEFAULT 0.0; " ...
		"DECLARE mult FLOAT DEFAULT 1.0; " ...
		"DECLARE done INT DEFAULT 0; " ...
		"DECLARE cur CURSOR FOR SELECT points FROM %splayertimes WHERE auth = authid AND points > 0.0 ORDER BY points DESC; " ...
		"DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1; " ...
		"OPEN cur; " ...
		"iter: LOOP " ...
			"FETCH cur INTO p; " ...
			"IF done THEN " ...
				"LEAVE iter; " ...
			"END IF; " ...
			"SET total = total + (p * mult); " ...
			"SET mult = mult * 0.975; " ...
		"END LOOP; " ...
		"CLOSE cur; " ...
		"RETURN total; " ...
		"END;;", gS_MySQLPrefix);

	RunLongFastQuery(bSuccess, "CREATE GetRecordPoints",
		"CREATE FUNCTION GetRecordPoints(rstyle INT, rtrack INT, rtime FLOAT, rmap CHAR(128), pointspertier FLOAT, stylemultiplier FLOAT) " ...
		"RETURNS FLOAT " ...
		"READS SQL DATA " ...
		"BEGIN " ...
		"DECLARE pwr, ppoints FLOAT DEFAULT 0.0; " ...
		"DECLARE ptier INT DEFAULT 1; " ...
		"SELECT tier FROM %smaptiers WHERE map = rmap INTO ptier; " ...
		"SELECT MIN(time) FROM %splayertimes WHERE map = rmap AND style = rstyle AND track = rtrack INTO pwr; " ...
		"IF rtrack > 0 THEN SET ptier = 1; END IF; " ...
		"SET ppoints = ((pointspertier * ptier) * 1.5) + (pwr / 15.0); " ...
		"IF rtime > pwr THEN SET ppoints = ppoints * (pwr / rtime); END IF; " ...
		"SET ppoints = ppoints * stylemultiplier; " ...
		"IF rtrack > 0 THEN SET ppoints = ppoints * 0.25; END IF; " ...
		"RETURN ppoints; " ...
		"END;;", gS_MySQLPrefix, gS_MySQLPrefix, gS_MySQLPrefix);

	SQL_FastQuery(gH_SQL, "DELIMITER ;");
	SQL_UnlockDatabase(gH_SQL);

	if(!bSuccess)
	{
		return;
	}

	OnMapStart();

	if(gB_Late)
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			OnClientConnected(i);
		}
	}
}

void RunLongFastQuery(bool &success, const char[] func, const char[] query, any ...)
{
	char sQuery[2048];
	VFormat(sQuery, 2048, query, 4);

	if(!SQL_FastQuery(gH_SQL, sQuery))
	{
		char sError[255];
		SQL_GetError(gH_SQL, sError, 255);
		LogError("Timer (rankings, %s) error! Reason: %s", func, sError);

		success = false;
	}
}

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	gF_PointsPerTier = gCV_PointsPerTier.FloatValue;
}

public void OnClientConnected(int client)
{
	gI_Rank[client] = 0;
	gF_Points[client] = 0.0;
}

public void OnClientPostAdminCheck(int client)
{
	if(!IsFakeClient(client))
	{
		UpdatePlayerRank(client);
	}
}

public void OnMapStart()
{
	if(gH_SQL == null)
	{
		return;
	}

	#if defined DEBUG
	PrintToServer("DEBUG: 1 (OnMapStart)");
	#endif

	UpdateRankedPlayers();

	GetCurrentMap(gS_Map, 160);
	GetMapDisplayName(gS_Map, gS_Map, 160);

	// Default tier.
	// I won't repeat the same mistake blacky has done with tier 3 being default..
	gI_Tier = 1;

	char sDriver[8];
	gH_SQL.Driver.GetIdentifier(sDriver, 8);
	
	if(!StrEqual(sDriver, "mysql", false))
	{
		SetFailState("Rankings will only support MySQL for the moment. Sorry.");
	}

	char sQuery[256];
	FormatEx(sQuery, 256, "SELECT tier FROM %smaptiers WHERE map = '%s';", gS_MySQLPrefix, gS_Map);
	gH_SQL.Query(SQL_GetMapTier_Callback, sQuery, 0, DBPrio_Low);
}

public void SQL_GetMapTier_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings, get map tier) error! Reason: %s", error);

		return;
	}

	#if defined DEBUG
	PrintToServer("DEBUG: 2 (SQL_GetMapTier_Callback)");
	#endif

	if(results.RowCount > 0 && results.FetchRow())
	{
		gI_Tier = results.FetchInt(0);

		#if defined DEBUG
		PrintToServer("DEBUG: 3 (tier: %d) (SQL_GetMapTier_Callback)", gI_Tier);
		#endif

		RecalculateAll(gS_Map);
		UpdateAllPoints();

		#if defined DEBUG
		PrintToServer("DEBUG: 4 (SQL_GetMapTier_Callback)");
		#endif

		char sQuery[256];
		FormatEx(sQuery, 256, "SELECT map, tier FROM %smaptiers;", gS_MySQLPrefix, gS_Map);
		gH_SQL.Query(SQL_FillTierCache_Callback, sQuery, 0, DBPrio_High);
	}

	else
	{
		char sQuery[256];
		FormatEx(sQuery, 256, "REPLACE INTO %smaptiers (map, tier) VALUES ('%s', %d);", gS_MySQLPrefix, gS_Map, gI_Tier);
		gH_SQL.Query(SQL_SetMapTier_Callback, sQuery, gI_Tier, DBPrio_High);
	}
}

public void SQL_FillTierCache_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings, fill tier cache) error! Reason: %s", error);

		return;
	}

	gA_ValidMaps.Clear();
	gA_MapTiers.Clear();

	while(results.FetchRow())
	{
		char sMap[160];
		results.FetchString(0, sMap, 160);

		int tier = results.FetchInt(1);

		gA_MapTiers.SetValue(sMap, tier);
		gA_ValidMaps.PushString(sMap);

		Call_StartForward(gH_Forwards_OnTierAssigned);
		Call_PushString(sMap);
		Call_PushCell(tier);
		Call_Finish();
	}

	gI_ValidMaps = gA_ValidMaps.Length;
	SortADTArray(gA_ValidMaps, Sort_Ascending, Sort_String);
}

void GuessBestMapName(const char[] input, char[] output, int size)
{
	if(gA_ValidMaps.FindString(input) != -1)
	{
		strcopy(output, size, input);

		return;
	}

	char sCache[128];

	for(int i = 0; i < gI_ValidMaps; i++)
	{
		gA_ValidMaps.GetString(i, sCache, 128);

		if(StrContains(sCache, input) != -1)
		{
			strcopy(output, size, sCache);

			return;
		}
	}
}

public void OnMapEnd()
{
	RecalculateAll(gS_Map);
}

public Action Command_Tier(int client, int args)
{
	int tier = gI_Tier;

	char sMap[128];
	strcopy(sMap, 128, gS_Map);

	if(args > 0)
	{
		GetCmdArgString(sMap, 128);
		GuessBestMapName(sMap, sMap, 128);
		
		if(!gA_MapTiers.GetValue(sMap, tier))
		{
			strcopy(sMap, 128, gS_Map);
		}
	}

	Shavit_PrintToChat(client, "%T", "CurrentTier", client, gS_ChatStrings[sMessageVariable], sMap, gS_ChatStrings[sMessageText], gS_ChatStrings[sMessageVariable2], tier, gS_ChatStrings[sMessageText]);

	return Plugin_Handled;
}

public Action Command_Rank(int client, int args)
{
	int target = client;

	if(args > 0)
	{
		char sArgs[MAX_TARGET_LENGTH];
		GetCmdArgString(sArgs, MAX_TARGET_LENGTH);

		target = FindTarget(client, sArgs, true, false);

		if(target == -1)
		{
			return Plugin_Handled;
		}
	}

	if(gF_Points[target] == 0.0)
	{
		Shavit_PrintToChat(client, "%T", "Unranked", client, gS_ChatStrings[sMessageVariable2], target, gS_ChatStrings[sMessageText]);

		return Plugin_Handled;
	}

	Shavit_PrintToChat(client, "%T", "Rank", client, gS_ChatStrings[sMessageVariable2], target, gS_ChatStrings[sMessageText],
		gS_ChatStrings[sMessageVariable], (gI_Rank[target] > gI_RankedPlayers)? gI_RankedPlayers:gI_Rank[target], gS_ChatStrings[sMessageText],
		gI_RankedPlayers,
		gS_ChatStrings[sMessageVariable], gF_Points[target], gS_ChatStrings[sMessageText]);

	return Plugin_Handled;
}

public Action Command_Top(int client, int args)
{
	gH_Top100Menu.SetTitle("%T (%d)\n ", "Top100", client, gI_RankedPlayers);
	gH_Top100Menu.Display(client, 60);

	return Plugin_Handled;
}

public int MenuHandler_Top(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[32];
		menu.GetItem(param2, sInfo, 32);

		if(gB_Stats && !StrEqual(sInfo, "-1"))
		{
			Shavit_OpenStatsMenu(param1, sInfo);
		}
	}

	return 0;
}

public Action Command_SetTier(int client, int args)
{
	char sArg[8];
	GetCmdArg(1, sArg, 8);
	
	int tier = StringToInt(sArg);

	if(args == 0 || tier < 1 || tier > 10)
	{
		ReplyToCommand(client, "%T", "ArgumentsMissing", client, "sm_settier <tier> (1-10)");

		return Plugin_Handled;
	}

	gI_Tier = tier;
	gA_MapTiers.SetValue(gS_Map, tier);

	Call_StartForward(gH_Forwards_OnTierAssigned);
	Call_PushString(gS_Map);
	Call_PushCell(tier);
	Call_Finish();

	Shavit_PrintToChat(client, "%T", "SetTier", client, gS_ChatStrings[sMessageVariable2], tier, gS_ChatStrings[sMessageText]);

	char sQuery[256];
	FormatEx(sQuery, 256, "REPLACE INTO %smaptiers (map, tier) VALUES ('%s', %d);", gS_MySQLPrefix, gS_Map, tier);

	gH_SQL.Query(SQL_SetMapTier_Callback, sQuery);

	return Plugin_Handled;
}

public void SQL_SetMapTier_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings, set map tier) error! Reason: %s", error);

		return;
	}

	RecalculateAll(gS_Map);
}

public Action Command_RecalcMap(int client, int args)
{
	RecalculateAll(gS_Map);
	UpdateAllPoints();

	ReplyToCommand(client, "Done.");

	return Plugin_Handled;
}

public Action Command_RecalcAll(int client, int args)
{
	ReplyToCommand(client, "- Started recalculating points for all maps. Check console for output.");

	Transaction trans = new Transaction();

	for(int i = 0; i < gI_Styles; i++)
	{
		char sQuery[192];

		if(gA_StyleSettings[i][bUnranked] || view_as<float>(gA_StyleSettings[i][fRankingMultiplier]) == 0.0)
		{
			FormatEx(sQuery, 192, "UPDATE %splayertimes SET points = 0 WHERE style = %d;", gS_MySQLPrefix, i);
		}

		else
		{
			FormatEx(sQuery, 192, "UPDATE %splayertimes SET points = GetRecordPoints(%d, track, time, map, %.1f, %.3f) WHERE style = %d;", gS_MySQLPrefix, i, gF_PointsPerTier, view_as<float>(gA_StyleSettings[i][fRankingMultiplier]), i);
		}

		trans.AddQuery(sQuery);
	}

	gH_SQL.Execute(trans, Trans_OnRecalcSuccess, Trans_OnRecalcFail, (client == 0)? 0:GetClientSerial(client));

	return Plugin_Handled;
}

public void Trans_OnRecalcSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	int client = (data == 0)? 0:GetClientFromSerial(data);

	if(client != 0)
	{
		SetCmdReplySource(SM_REPLY_TO_CONSOLE);
	}

	ReplyToCommand(client, "- Finished recalculating all points. Recalculating user points, top 100 and user cache.");

	UpdateAllPoints();
	UpdateTop100();

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && IsClientAuthorized(i))
		{
			UpdatePlayerRank(i);
		}
	}

	ReplyToCommand(client, "- Done.");
}

public void Trans_OnRecalcFail(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("Timer (rankings) error! Recalculation failed. Reason: %s", error);
}

void RecalculateAll(const char[] map)
{
	#if defined DEBUG
	LogError("DEBUG: 5 (RecalculateAll)");
	#endif

	for(int i = 0; i < TRACKS_SIZE; i++)
	{
		for(int j = 0; j < gI_Styles; j++)
		{
			if(gA_StyleSettings[j][bUnranked])
			{
				continue;
			}

			RecalculateMap(map, i, j);
		}
	}
}

public void Shavit_OnFinish_Post(int client, int style, float time, int jumps, int strafes, float sync, int rank, int overwrite, int track)
{
	RecalculateMap(gS_Map, track, style);
}

void RecalculateMap(const char[] map, const int track, const int style)
{
	#if defined DEBUG
	PrintToServer("Recalculating points. (%s, %d, %d)", map, track, style);
	#endif

	char sQuery[192];
	FormatEx(sQuery, 192, "UPDATE %splayertimes SET points = GetRecordPoints(%d, %d, time, '%s', %.1f, %.3f) WHERE style = %d AND track = %d AND map = '%s';", gS_MySQLPrefix, style, track, map, gF_PointsPerTier, gA_StyleSettings[style][fRankingMultiplier], style, track, map);

	gH_SQL.Query(SQL_Recalculate_Callback, sQuery, 0, DBPrio_High);

	#if defined DEBUG
	PrintToServer("Sent query.");
	#endif
}

public void SQL_Recalculate_Callback(Database db, DBResultSet results, const char[] error, DataPack data)
{
	if(results == null)
	{
		LogError("Timer (rankings, recalculate map points) error! Reason: %s", error);

		return;
	}

	#if defined DEBUG
	PrintToServer("Recalculated.");
	#endif
}

void UpdateAllPoints()
{
	#if defined DEBUG
	LogError("DEBUG: 6 (UpdateAllPoints)");
	#endif

	char sQuery[128];
	FormatEx(sQuery, 128, "UPDATE %susers SET points = GetWeightedPoints(auth);", gS_MySQLPrefix);
	gH_SQL.Query(SQL_UpdateAllPoints_Callback, sQuery);
}

public void SQL_UpdateAllPoints_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings, update all points) error! Reason: %s", error);

		return;
	}
}

void UpdatePlayerRank(int client)
{
	gI_Rank[client] = 0;
	gF_Points[client] = 0.0;

	char sAuthID[32];

	if(GetClientAuthId(client, AuthId_Steam3, sAuthID, 32))
	{
		// if there's any issue with this query,
		// add "ORDER BY points DESC " before "LIMIT 1"
		char sQuery[512];
		FormatEx(sQuery, 512, "SELECT p.points, COUNT(*) rank FROM %susers u JOIN (SELECT points FROM %susers WHERE auth = '%s' LIMIT 1) p WHERE u.points >= p.points LIMIT 1;",
			gS_MySQLPrefix, gS_MySQLPrefix, sAuthID);

		gH_SQL.Query(SQL_UpdatePlayerRank_Callback, sQuery, GetClientSerial(client), DBPrio_Low);
	}
}

public void SQL_UpdatePlayerRank_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings, update player rank) error! Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	if(results.FetchRow())
	{
		gF_Points[client] = results.FetchFloat(0);
		gI_Rank[client] = (gF_Points[client] > 0.0)? results.FetchInt(1):0;
	}
}

void UpdateRankedPlayers()
{
	char sQuery[512];
	FormatEx(sQuery, 512, "SELECT COUNT(*) count FROM %susers WHERE points > 0.0;", gS_MySQLPrefix);
	gH_SQL.Query(SQL_UpdateRankedPlayers_Callback, sQuery, 0, DBPrio_High);
}

public void SQL_UpdateRankedPlayers_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings, update ranked players) error! Reason: %s", error);

		return;
	}

	if(results.FetchRow())
	{
		gI_RankedPlayers = results.FetchInt(0);

		UpdateTop100();
	}
}

void UpdateTop100()
{
	char sQuery[512];
	FormatEx(sQuery, 512, "SELECT auth, name, FORMAT(points, 2) FROM %susers WHERE points > 0.0 ORDER BY points DESC LIMIT 100;", gS_MySQLPrefix);
	gH_SQL.Query(SQL_UpdateTop100_Callback, sQuery, 0, DBPrio_Low);
}

public void SQL_UpdateTop100_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings, update top 100) error! Reason: %s", error);

		return;
	}

	if(gH_Top100Menu != null)
	{
		delete gH_Top100Menu;
	}

	gH_Top100Menu = new Menu(MenuHandler_Top);

	int row = 0;

	while(results.FetchRow())
	{
		if(row > 100)
		{
			break;
		}

		char sAuthID[32];
		results.FetchString(0, sAuthID, 32);

		char sName[MAX_NAME_LENGTH];
		results.FetchString(1, sName, MAX_NAME_LENGTH);

		char sPoints[16];
		results.FetchString(2, sPoints, 16);

		char sDisplay[96];
		FormatEx(sDisplay, 96, "#%d - %s (%s)", (++row), sName, sPoints);
		gH_Top100Menu.AddItem(sAuthID, sDisplay);
	}

	if(gH_Top100Menu.ItemCount == 0)
	{
		char sDisplay[64];
		FormatEx(sDisplay, 64, "%t", "NoRankedPlayers");
		gH_Top100Menu.AddItem("-1", sDisplay);
	}

	gH_Top100Menu.ExitButton = true;
}

void GetTrackName(int client, int track, char[] output, int size)
{
	if(track < 0 || track >= TRACKS_SIZE)
	{
		FormatEx(output, size, "%T", "Track_Unknown", client);

		return;
	}

	static char sTrack[16];
	FormatEx(sTrack, 16, "Track_%d", track);
	FormatEx(output, size, "%T", sTrack, client);
}

public int Native_GetMapTier(Handle handler, int numParams)
{
	int tier = 0;

	char sMap[128];
	GetNativeString(1, sMap, 128);

	if(!gA_MapTiers.GetValue(sMap, tier))
	{
		return 0;
	}

	return tier;
}

public int Native_GetMapTiers(Handle handler, int numParams)
{
	return view_as<int>(CloneHandle(gA_MapTiers, handler));
}

public int Native_GetPoints(Handle handler, int numParams)
{
	return view_as<int>(gF_Points[GetNativeCell(1)]);
}

public int Native_GetRank(Handle handler, int numParams)
{
	return gI_Rank[GetNativeCell(1)];
}

public int Native_GetRankedPlayers(Handle handler, int numParams)
{
	return gI_RankedPlayers;
}

public int Native_Rankings_DeleteMap(Handle handler, int numParams)
{
	char sMap[160];
	GetNativeString(1, sMap, 160);

	char sQuery[256];
	FormatEx(sQuery, 256, "DELETE FROM %smaptiers WHERE map = '%s';", gS_MySQLPrefix, sMap);
	gH_SQL.Query(SQL_DeleteMap_Callback, sQuery, StrEqual(gS_Map, sMap, false), DBPrio_High);
}

public void SQL_DeleteMap_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (rankings deletemap) SQL query failed. Reason: %s", error);

		return;
	}

	if(view_as<bool>(data))
	{
		gI_Tier = 1;
		
		UpdateAllPoints();
		UpdateRankedPlayers();
	}
}
