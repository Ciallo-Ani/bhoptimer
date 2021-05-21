/*
 * shavit's Timer - Map Zones
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

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <convar_class>

#undef REQUIRE_PLUGIN
#include <shavit>
#include <adminmenu>

#undef REQUIRE_EXTENSIONS
#include <cstrike>

#pragma semicolon 1
#pragma dynamic 131072
#pragma newdecls required

//#define DEBUG
#define EF_NODRAW 32

EngineVersion gEV_Type = Engine_Unknown;

Database gH_SQL = null;
bool gB_Connected = false;
bool gB_MySQL = false;

char gS_Map[160];

char gS_ZoneNames[][] =
{
	"Start Zone", // starts timer
	"End Zone", // stops timer
	"Stage Zone", // stage zone
	"Checkpoint Zone", // track checkpoint zone
	"Stop Timer", // stops the player's timer
	"Teleport Zone", // teleports to a defined point
	"Mark Zone" // do nothing, mainly used for marking map like clip, trigger_push and so on, with hookzone collocation is recommended
};

enum struct zone_cache_t
{
	bool bZoneInitialized;
	int iZoneType;
	int iZoneTrack; // 0 - main, 1 - bonus etc
	int iEntityID;
	int iDatabaseID;
	int iZoneFlags;
	int iZoneData;
	char sZoneHookname[128];
}

enum struct zone_settings_t
{
	bool bVisible;
	int iRed;
	int iGreen;
	int iBlue;
	int iAlpha;
	float fWidth;
	bool bFlatZone;
	bool bUseVanillaSprite;
	bool bNoHalo;
	int iBeam;
	int iHalo;
	char sBeam[PLATFORM_MAX_PATH];
}

enum
{
	ZF_ForceRender = (1 << 0)
};

int gI_ZoneType[MAXPLAYERS+1];

// 0 - nothing
// 1 - wait for E tap to setup first coord
// 2 - wait for E tap to setup second coord
// 3 - confirm
int gI_MapStep[MAXPLAYERS+1];

float gF_Modifier[MAXPLAYERS+1];
int gI_GridSnap[MAXPLAYERS+1];
bool gB_SnapToWall[MAXPLAYERS+1];
bool gB_CursorTracing[MAXPLAYERS+1];
int gI_ZoneFlags[MAXPLAYERS+1];
int gI_ZoneData[MAXPLAYERS+1][ZONETYPES_SIZE];
int gI_ZoneMaxData[TRACKS_SIZE];
bool gB_WaitingForChatInput[MAXPLAYERS+1];
bool gB_HookZoneConfirm[MAXPLAYERS+1];
bool gB_ZoneDataInput[MAXPLAYERS+1];
bool gB_CommandToEdit[MAXPLAYERS+1];
bool gB_SingleStageTiming[MAXPLAYERS+1];
bool gB_ShowTriggers[MAXPLAYERS+1];

// cache
float gV_Point1[MAXPLAYERS+1][3];
float gV_Point2[MAXPLAYERS+1][3];
float gV_Teleport[MAXPLAYERS+1][3];
float gV_WallSnap[MAXPLAYERS+1][3];
bool gB_Button[MAXPLAYERS+1];
bool gB_InsideZone[MAXPLAYERS+1][ZONETYPES_SIZE][TRACKS_SIZE];
bool gB_InsideZoneID[MAXPLAYERS+1][MAX_ZONES];
int gI_InsideZoneIndex[MAXPLAYERS+1];
int gI_ZoneTrack[MAXPLAYERS+1];
int gI_ZoneDatabaseID[MAXPLAYERS+1];
int gI_ZoneID[MAXPLAYERS+1];
char gS_ZoneHookname[MAXPLAYERS+1][128];
int gI_HookZoneIndex[MAXPLAYERS+1];

// zone cache
zone_settings_t gA_ZoneSettings[ZONETYPES_SIZE][TRACKS_SIZE];
zone_cache_t gA_ZoneCache[MAX_ZONES];
int gI_MapZones = 0;
float gV_MapZones[MAX_ZONES][2][3];
float gV_MapZones_Visual[MAX_ZONES][8][3];
float gV_Destinations[MAX_ZONES][3];
float gV_ZoneCenter[MAX_ZONES][3];
float gV_ZoneCenter_Angle[MAX_ZONES][3];
int gI_EntityZone[4096];
ArrayList gA_Triggers;
ArrayList gA_HookTriggers;
bool gB_ZonesCreated = false;
int gI_Bonuses;
int gI_Stages; // how many stages in a map, default 1.
int gI_Checkpoints; // how many checkpoint zones in a map, default 0.
int gI_ClientCurrentStage[MAXPLAYERS+1];
int gI_ClientCurrentCP[MAXPLAYERS+1];

char gS_BeamSprite[PLATFORM_MAX_PATH];
char gS_BeamSpriteIgnoreZ[PLATFORM_MAX_PATH];
int gI_BeamSpriteIgnoreZ;
int gI_Offset_m_fEffects = -1;

// admin menu
TopMenu gH_AdminMenu = null;
TopMenuObject gH_TimerCommands = INVALID_TOPMENUOBJECT;

// misc cache
bool gB_Late = false;

// cvars
Convar gCV_Interval = null;
Convar gCV_TeleportToStart = null;
Convar gCV_TeleportToEnd = null;
Convar gCV_UseCustomSprite = null;
Convar gCV_Height = null;
Convar gCV_Offset = null;
Convar gCV_EnforceTracks = null;
Convar gCV_BoxOffset = null;

// handles
Handle gH_DrawEverything = null;

// table prefix
char gS_MySQLPrefix[32];

// chat settings
chatstrings_t gS_ChatStrings;

// forwards
Handle gH_Forwards_EnterZone = null;
Handle gH_Forwards_LeaveZone = null;
Handle gH_Forwards_OnStage = null;
Handle gH_Forwards_OnEndZone = null;

int gI_LastStage[MAXPLAYERS+1];
int gI_LastCheckpoint[MAXPLAYERS+1];
bool gB_IntoStage[MAXPLAYERS+1];
bool gB_IntoCheckpoint[MAXPLAYERS+1];
bool gB_LinearMap;

public Plugin myinfo =
{
	name = "[shavit] Map Zones",
	author = "shavit",
	description = "Map zones for shavit's bhop timer.",
	version = SHAVIT_VERSION,
	url = "https://github.com/shavitush/bhoptimer"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// zone natives
	CreateNative("Shavit_GetZoneData", Native_GetZoneData);
	CreateNative("Shavit_GetZoneFlags", Native_GetZoneFlags);
	CreateNative("Shavit_GetClientStage", Native_GetClientStage);
	CreateNative("Shavit_GetClientCheckpoint", Native_GetClientCheckpoint);
	CreateNative("Shavit_GetMapBonuses", Native_GetMapBonuses);
	CreateNative("Shavit_GetMapStages", Native_GetMapStages);
	CreateNative("Shavit_GetMapCheckpoints", Native_GetMapCheckpoints);
	CreateNative("Shavit_InsideZone", Native_InsideZone);
	CreateNative("Shavit_InsideZoneGetID", Native_InsideZoneGetID);
	CreateNative("Shavit_IsLinearMap", Native_IsLinearMap);
	CreateNative("Shavit_IsClientCreatingZone", Native_IsClientCreatingZone);
	CreateNative("Shavit_IsClientSingleStageTiming", Native_IsClientSingleStageTiming);
	CreateNative("Shavit_IntoStage", Native_IntoStage);
	CreateNative("Shavit_IntoCheckpoint", Native_IntoCheckpoint);
	CreateNative("Shavit_ZoneExists", Native_ZoneExists);
	CreateNative("Shavit_Zones_DeleteMap", Native_Zones_DeleteMap);

	// registers library, check "bool LibraryExists(const char[] name)" in order to use with other plugins
	RegPluginLibrary("shavit-zones");

	gB_Late = late;

	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("shavit-common.phrases");
	LoadTranslations("shavit-zones.phrases");

	// game specific
	gEV_Type = GetEngineVersion();

	gI_Offset_m_fEffects = FindSendPropInfo("CBaseEntity", "m_fEffects");
	
	if(gI_Offset_m_fEffects == -1)
	{
		SetFailState("[Show Zones] Could not find CBaseEntity:m_fEffects");
	}
	
	RegConsoleCmd("sm_showzones", Command_Showzones, "Command to dynamically toggle shavit's zones trigger visibility");

	// menu
	RegAdminCmd("sm_zone", Command_Zones, ADMFLAG_RCON, "Opens the mapzones menu.");
	RegAdminCmd("sm_zones", Command_Zones, ADMFLAG_RCON, "Opens the mapzones menu.");
	RegAdminCmd("sm_mapzone", Command_Zones, ADMFLAG_RCON, "Opens the mapzones menu. Alias of sm_zones.");
	RegAdminCmd("sm_mapzones", Command_Zones, ADMFLAG_RCON, "Opens the mapzones menu. Alias of sm_zones.");
	RegAdminCmd("sm_hookzone", Command_HookZones, ADMFLAG_RCON, "Opens the mapHookzones menu.");
	RegAdminCmd("sm_hookzones", Command_HookZones, ADMFLAG_RCON, "Opens the mapHookzones menu. Alias of sm_hookzone.");

	RegAdminCmd("sm_delzone", Command_DeleteZone, ADMFLAG_RCON, "Delete a mapzone");
	RegAdminCmd("sm_delzones", Command_DeleteZone, ADMFLAG_RCON, "Delete a mapzone");
	RegAdminCmd("sm_deletezone", Command_DeleteZone, ADMFLAG_RCON, "Delete a mapzone");
	RegAdminCmd("sm_deletezones", Command_DeleteZone, ADMFLAG_RCON, "Delete a mapzone");
	RegAdminCmd("sm_deleteallzones", Command_DeleteAllZones, ADMFLAG_RCON, "Delete all mapzones");

	RegAdminCmd("sm_modifier", Command_Modifier, ADMFLAG_RCON, "Changes the axis modifier for the zone editor. Usage: sm_modifier <number>");

	RegAdminCmd("sm_editzone", Command_ZoneEdit, ADMFLAG_RCON, "Modify an existing zone.");
	RegAdminCmd("sm_editzones", Command_ZoneEdit, ADMFLAG_RCON, "Modify an existing zone.");
	
	RegAdminCmd("sm_reloadzonesettings", Command_ReloadZoneSettings, ADMFLAG_ROOT, "Reloads the zone settings.");

	RegConsoleCmd("sm_stages", Command_Stages, "Opens the stage menu. Usage: sm_stages [stage #]");
	RegConsoleCmd("sm_stage", Command_Stages, "Opens the stage menu. Usage: sm_stage [stage #]");
	RegConsoleCmd("sm_s", Command_Stages, "Opens the stage menu. Usage: sm_stage [stage #]");

	RegConsoleCmd("sm_back", Command_Back, "Go back to the current stage zone.");
	RegConsoleCmd("sm_teleport", Command_Back, "Go back to the current stage zone. Alias of sm_back");

	RegConsoleCmd("sm_test", Command_Test);

	// events
	HookEvent("round_start", Round_Start);
	HookEvent("player_spawn", Player_Spawn);

	// forwards
	gH_Forwards_EnterZone = CreateGlobalForward("Shavit_OnEnterZone", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	gH_Forwards_LeaveZone = CreateGlobalForward("Shavit_OnLeaveZone", ET_Event, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	gH_Forwards_OnStage = CreateGlobalForward("Shavit_OnStage", ET_Event, Param_Cell, Param_Cell);
	gH_Forwards_OnEndZone = CreateGlobalForward("Shavit_OnEndZone", ET_Event, Param_Cell);

	// cvars and stuff
	gCV_Interval = new Convar("shavit_zones_interval", "1.0", "Interval between each time a mapzone is being drawn to the players.", 0, true, 0.5, true, 5.0);
	gCV_TeleportToStart = new Convar("shavit_zones_teleporttostart", "1", "Teleport players to the start zone on timer restart?\n0 - Disabled\n1 - Enabled", 0, true, 0.0, true, 1.0);
	gCV_TeleportToEnd = new Convar("shavit_zones_teleporttoend", "1", "Teleport players to the end zone on sm_end?\n0 - Disabled\n1 - Enabled", 0, true, 0.0, true, 1.0);
	gCV_UseCustomSprite = new Convar("shavit_zones_usecustomsprite", "1", "Use custom sprite for zone drawing?\nSee `configs/shavit-zones.cfg`.\n0 - Disabled\n1 - Enabled", 0, true, 0.0, true, 1.0);
	gCV_Height = new Convar("shavit_zones_height", "128.0", "Height to use for the start zone.", 0, true, 0.0, false);
	gCV_Offset = new Convar("shavit_zones_offset", "0.5", "When calculating a zone's *VISUAL* box, by how many units, should we scale it to the center?\n0.0 - no downscaling. Values above 0 will scale it inward and negative numbers will scale it outwards.\nAdjust this value if the zones clip into walls.");
	gCV_EnforceTracks = new Convar("shavit_zones_enforcetracks", "1", "Enforce zone tracks upon entry?\n0 - allow every zone except for start/end to affect users on every zone.\n1 - require the user's track to match the zone's track.", 0, true, 0.0, true, 1.0);
	gCV_BoxOffset = new Convar("shavit_zones_box_offset", "16", "Offset zone trigger boxes by this many unit\n0 - matches players bounding box\n16 - matches players center");

	gCV_Interval.AddChangeHook(OnConVarChanged);
	gCV_UseCustomSprite.AddChangeHook(OnConVarChanged);
	gCV_Offset.AddChangeHook(OnConVarChanged);

	Convar.AutoExecConfig();

	for(int i = 0; i < ZONETYPES_SIZE; i++)
	{
		for(int j = 0; j < TRACKS_SIZE; j++)
		{
			gA_ZoneSettings[i][j].bVisible = true;
			gA_ZoneSettings[i][j].iRed = 255;
			gA_ZoneSettings[i][j].iGreen = 255;
			gA_ZoneSettings[i][j].iBlue = 255;
			gA_ZoneSettings[i][j].iAlpha = 255;
			gA_ZoneSettings[i][j].fWidth = 2.0;
			gA_ZoneSettings[i][j].bFlatZone = false;
		}
	}

	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && !IsFakeClient(i))
		{
			OnClientPutInServer(i);
		}
	}

	SQL_DBConnect();
}

public void OnAllPluginsLoaded()
{
	// admin menu
	if(LibraryExists("adminmenu") && ((gH_AdminMenu = GetAdminTopMenu()) != null))
	{
		OnAdminMenuReady(gH_AdminMenu);
	}
}

public void OnLibraryAdded(const char[] name)
{
	if(strcmp(name, "adminmenu") == 0)
	{
		if ((gH_AdminMenu = GetAdminTopMenu()) != null)
		{
			OnAdminMenuReady(gH_AdminMenu);
		}
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if(strcmp(name, "adminmenu") == 0)
	{
		gH_AdminMenu = null;
		gH_TimerCommands = INVALID_TOPMENUOBJECT;
	}
} 

public void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if(convar == gCV_Interval)
	{
		delete gH_DrawEverything;
		gH_DrawEverything = CreateTimer(gCV_Interval.FloatValue, Timer_DrawEverything, INVALID_HANDLE, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}

	else if(convar == gCV_Offset && gI_MapZones > 0)
	{
		for(int i = 0; i < gI_MapZones; i++)
		{
			if(!gA_ZoneCache[i].bZoneInitialized)
			{
				continue;
			}

			gV_MapZones_Visual[i][0][0] = gV_MapZones[i][0][0];
			gV_MapZones_Visual[i][0][1] = gV_MapZones[i][0][1];
			gV_MapZones_Visual[i][0][2] = gV_MapZones[i][0][2];
			gV_MapZones_Visual[i][7][0] = gV_MapZones[i][1][0];
			gV_MapZones_Visual[i][7][1] = gV_MapZones[i][1][1];
			gV_MapZones_Visual[i][7][2] = gV_MapZones[i][1][2];

			CreateZonePoints(gV_MapZones_Visual[i], gCV_Offset.FloatValue);
		}
	}

	else if(convar == gCV_UseCustomSprite && !StrEqual(oldValue, newValue))
	{
		LoadZoneSettings();
	}
}

public void OnAdminMenuCreated(Handle topmenu)
{
	if(gH_AdminMenu == null || (topmenu == gH_AdminMenu && gH_TimerCommands != INVALID_TOPMENUOBJECT))
	{
		return;
	}

	gH_TimerCommands = gH_AdminMenu.AddCategory("Timer Commands", CategoryHandler, "shavit_admin", ADMFLAG_RCON);
}

public void CategoryHandler(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayTitle)
	{
		FormatEx(buffer, maxlength, "%T:", "TimerCommands", param);
	}

	else if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%T", "TimerCommands", param);
	}
}

public void OnAdminMenuReady(Handle topmenu)
{
	if((gH_AdminMenu = GetAdminTopMenu()) != null)
	{
		if(gH_TimerCommands == INVALID_TOPMENUOBJECT)
		{
			gH_TimerCommands = gH_AdminMenu.FindCategory("Timer Commands");

			if(gH_TimerCommands == INVALID_TOPMENUOBJECT)
			{
				OnAdminMenuCreated(topmenu);
			}
		}

		gH_AdminMenu.AddItem("sm_zones", AdminMenu_Zones, gH_TimerCommands, "sm_zones", ADMFLAG_RCON);
		gH_AdminMenu.AddItem("sm_deletezone", AdminMenu_DeleteZone, gH_TimerCommands, "sm_deletezone", ADMFLAG_RCON);
		gH_AdminMenu.AddItem("sm_deleteallzones", AdminMenu_DeleteAllZones, gH_TimerCommands, "sm_deleteallzones", ADMFLAG_RCON);
		gH_AdminMenu.AddItem("sm_zoneedit", AdminMenu_ZoneEdit, gH_TimerCommands, "sm_zoneedit", ADMFLAG_RCON);
	}
}

public void AdminMenu_Zones(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%T", "AddMapZone", param);
	}

	else if(action == TopMenuAction_SelectOption)
	{
		Command_Zones(param, 0);
	}
}

public void AdminMenu_DeleteZone(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%T", "DeleteMapZone", param);
	}

	else if(action == TopMenuAction_SelectOption)
	{
		Command_DeleteZone(param, 0);
	}
}

public void AdminMenu_DeleteAllZones(Handle topmenu,  TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%T", "DeleteAllMapZone", param);
	}

	else if(action == TopMenuAction_SelectOption)
	{
		Command_DeleteAllZones(param, 0);
	}
}

public void AdminMenu_ZoneEdit(Handle topmenu, TopMenuAction action, TopMenuObject object_id, int param, char[] buffer, int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		FormatEx(buffer, maxlength, "%T", "ZoneEdit", param);
	}

	else if(action == TopMenuAction_SelectOption)
	{
		Reset(param);
		OpenEditMenu(param);
	}
}

public int Native_ZoneExists(Handle handler, int numParams)
{
	return (GetZoneIndex(GetNativeCell(1), GetNativeCell(2)) != -1);
}

public int Native_GetZoneData(Handle handler, int numParams)
{
	return gA_ZoneCache[GetNativeCell(1)].iZoneData;
}

public int Native_GetZoneFlags(Handle handler, int numParams)
{
	return gA_ZoneCache[GetNativeCell(1)].iZoneFlags;
}

public int Native_InsideZone(Handle handler, int numParams)
{
	return InsideZone(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3));
}

public int Native_InsideZoneGetID(Handle handler, int numParams)
{
	int client = GetNativeCell(1);
	int iType = GetNativeCell(2);
	int iTrack = GetNativeCell(3);

	for(int i = 0; i < MAX_ZONES; i++)
	{
		if(gB_InsideZoneID[client][i] &&
			gA_ZoneCache[i].iZoneType == iType &&
			(gA_ZoneCache[i].iZoneTrack == iTrack || iTrack == -1))
		{
			SetNativeCellRef(4, i);

			return true;
		}
	}

	return false;
}

public int Native_IsLinearMap(Handle handler, int numParams)
{
	return gB_LinearMap;
}

public int Native_Zones_DeleteMap(Handle handler, int numParams)
{
	char sMap[160];
	GetNativeString(1, sMap, 160);

	char sQuery[256];
	FormatEx(sQuery, 256, "DELETE FROM %smapzones WHERE map = '%s';", gS_MySQLPrefix, sMap);
	gH_SQL.Query(SQL_DeleteMap_Callback, sQuery, StrEqual(gS_Map, sMap, false), DBPrio_High);
}

public void SQL_DeleteMap_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (zones deletemap) SQL query failed. Reason: %s", error);

		return;
	}

	if(view_as<bool>(data))
	{
		OnMapStart();
	}
}

bool InsideZone(int client, int type, int track)
{
	if(track != -1)
	{
		return gB_InsideZone[client][type][track];
	}

	else
	{
		for(int i = 0; i < TRACKS_SIZE; i++)
		{
			if(gB_InsideZone[client][type][i])
			{
				return true;
			}
		}
	}

	return false;
}

public int Native_IsClientCreatingZone(Handle handler, int numParams)
{
	return (gI_MapStep[GetNativeCell(1)] != 0);
}

public int Native_IsClientSingleStageTiming(Handle handler, int numParams)
{
	return gB_SingleStageTiming[GetNativeCell(1)];
}

public int Native_IntoStage(Handle handler, int numParams)
{
	int client = GetNativeCell(1);

	if(gB_IntoStage[client])
	{
		gB_IntoStage[client] = false;

		return true;
	}

	return false;
}

public int Native_IntoCheckpoint(Handle handler, int numParams)
{
	int client = GetNativeCell(1);

	if(gB_IntoCheckpoint[client])
	{
		gB_IntoCheckpoint[client] = false;

		return true;
	}
	
	return false;
}

public int Native_GetClientStage(Handle handler, int numParams)
{
	return (gI_ClientCurrentStage[GetNativeCell(1)]);
}

public int Native_GetClientCheckpoint(Handle handler, int numParams)
{
	return (gI_ClientCurrentCP[GetNativeCell(1)]);
}

public int Native_GetMapBonuses(Handle handler, int numParams)
{
	return gI_Bonuses;
}

public int Native_GetMapStages(Handle handler, int numParams)
{
	return gI_Stages;
}

public int Native_GetMapCheckpoints(Handle handler, int numParams)
{
	return gI_Checkpoints;
}

bool LoadZonesConfig()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, PLATFORM_MAX_PATH, "configs/shavit-zones.cfg");

	KeyValues kv = new KeyValues("shavit-zones");
	
	if(!kv.ImportFromFile(sPath))
	{
		delete kv;

		return false;
	}

	kv.JumpToKey("Sprites");
	kv.GetString("beam", gS_BeamSprite, PLATFORM_MAX_PATH);
	kv.GetString("beam_ignorez", gS_BeamSpriteIgnoreZ, PLATFORM_MAX_PATH, gS_BeamSprite);

	char sDownloads[PLATFORM_MAX_PATH * 8];
	kv.GetString("downloads", sDownloads, (PLATFORM_MAX_PATH * 8));

	char sDownloadsExploded[PLATFORM_MAX_PATH][PLATFORM_MAX_PATH];
	int iDownloads = ExplodeString(sDownloads, ";", sDownloadsExploded, PLATFORM_MAX_PATH, PLATFORM_MAX_PATH, false);

	for(int i = 0; i < iDownloads; i++)
	{
		if(strlen(sDownloadsExploded[i]) > 0)
		{
			TrimString(sDownloadsExploded[i]);
			AddFileToDownloadsTable(sDownloadsExploded[i]);
		}
	}

	kv.GoBack();
	kv.JumpToKey("Colors");
	kv.JumpToKey("Start"); // A stupid and hacky way to achieve what I want. It works though.

	int i = 0;
	int track;

	do
	{
		// retroactively don't respect custom spawn settings
		char sSection[32];
		kv.GetSectionName(sSection, 32);

		if(StrContains(sSection, "SPAWN POINT", false) != -1)
		{
			continue;
		}

		track = (i / ZONETYPES_SIZE);

		if(track >= TRACKS_SIZE)
		{
			break;
		}

		int index = (i % ZONETYPES_SIZE);

		gA_ZoneSettings[index][track].bVisible = view_as<bool>(kv.GetNum("visible", 1));
		gA_ZoneSettings[index][track].iRed = kv.GetNum("red", 255);
		gA_ZoneSettings[index][track].iGreen = kv.GetNum("green", 255);
		gA_ZoneSettings[index][track].iBlue = kv.GetNum("blue", 255);
		gA_ZoneSettings[index][track].iAlpha = kv.GetNum("alpha", 255);
		gA_ZoneSettings[index][track].fWidth = kv.GetFloat("width", 2.0);
		gA_ZoneSettings[index][track].bFlatZone = view_as<bool>(kv.GetNum("flat", false));
		gA_ZoneSettings[index][track].bUseVanillaSprite = view_as<bool>(kv.GetNum("vanilla_sprite", false));
		gA_ZoneSettings[index][track].bNoHalo = view_as<bool>(kv.GetNum("no_halo", false));
		kv.GetString("beam", gA_ZoneSettings[index][track].sBeam, sizeof(zone_settings_t::sBeam), "");

		i++;
	}

	while(kv.GotoNextKey(false));

	delete kv;

	// copy bonus#1 settings to the rest of the bonuses
	for (++track; track < TRACKS_SIZE; track++)
	{
		for (int type = 0; type < ZONETYPES_SIZE; type++)
		{
			gA_ZoneSettings[type][track] = gA_ZoneSettings[type][Track_Bonus];
		}
	}

	return true;
}

void LoadZoneSettings()
{
	if(!LoadZonesConfig())
	{
		SetFailState("Cannot open \"configs/shavit-zones.cfg\". Make sure this file exists and that the server has read permissions to it.");
	}

	int defaultBeam;
	int defaultHalo;
	int customBeam;

	if(IsSource2013(gEV_Type))
	{
		defaultBeam = PrecacheModel("sprites/laser.vmt", true);
		defaultHalo = PrecacheModel("sprites/halo01.vmt", true);
	}
	else
	{
		defaultBeam = PrecacheModel("sprites/laserbeam.vmt", true);
		defaultHalo = PrecacheModel("sprites/glow01.vmt", true);
	}

	if(gCV_UseCustomSprite.BoolValue)
	{
		customBeam = PrecacheModel(gS_BeamSprite, true);
	}
	else
	{
		customBeam = defaultBeam;
	}

	gI_BeamSpriteIgnoreZ = PrecacheModel(gS_BeamSpriteIgnoreZ, true);

	for (int i = 0; i < ZONETYPES_SIZE; i++)
	{
		for (int j = 0; j < TRACKS_SIZE; j++)
		{

			if (gA_ZoneSettings[i][j].bUseVanillaSprite)
			{
				gA_ZoneSettings[i][j].iBeam = defaultBeam;
			}
			else
			{
				gA_ZoneSettings[i][j].iBeam = (gA_ZoneSettings[i][j].sBeam[0] != 0)
					? PrecacheModel(gA_ZoneSettings[i][j].sBeam, true)
					: customBeam;
			}

			gA_ZoneSettings[i][j].iHalo = (gA_ZoneSettings[i][j].bNoHalo) ? 0 : defaultHalo;
		}
	}
}

void InitTeleDestinations()
{
	int iEnt = -1;

	ArrayList aTeleDestination = new ArrayList();

	while ((iEnt = FindEntityByClassname(iEnt, "info_teleport_destination")) != -1)
	{
		aTeleDestination.Push(iEnt);
	}

	for(int i = 0; i < gI_MapZones; i++)
	{
		for(int j = 0; j < aTeleDestination.Length; j++)
		{
			int entity = aTeleDestination.Get(j);

			if(IsEntityInsideZone(entity, gV_MapZones_Visual[i]))
			{
				float origin[3];
				GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
				gV_ZoneCenter[i][0] = origin[0];
				gV_ZoneCenter[i][1] = origin[1];
				gV_ZoneCenter[i][2] = origin[2];

				float ang[3];
				GetEntPropVector(iEnt, Prop_Send, "m_angRotation", ang);
				gV_ZoneCenter_Angle[i][0] = ang[0];
				gV_ZoneCenter_Angle[i][1] = ang[1];
				gV_ZoneCenter_Angle[i][2] = ang[2];

				break;
			}
		}
	}
}

void FindTriggers()
{
	delete gA_Triggers;
	gA_Triggers = new ArrayList();

	int iEnt = -1;
	int iCount = 1;

	while((iEnt = FindEntityByClassname(iEnt, "trigger_multiple")) != -1)
	{
		char sBuffer[128];
		GetEntPropString(iEnt, Prop_Send, "m_iName", sBuffer, 128, 0);

		if(strlen(sBuffer) == 0)
		{
			char sTargetname[64];
			FormatEx(sTargetname, 64, "trigger_multiple_#%d", iCount);
			DispatchKeyValue(iEnt, "targetname", sTargetname);
		}

		iCount++;
		gA_Triggers.Push(iEnt);
	}

	iCount = 1;

	while((iEnt = FindEntityByClassname(iEnt, "trigger_teleport")) != -1)
	{
		char sBuffer[128];
		GetEntPropString(iEnt, Prop_Send, "m_iName", sBuffer, 128, 0);

		if(strlen(sBuffer) == 0)
		{
			char sTargetname[64];
			FormatEx(sTargetname, 64, "trigger_teleport_#%d", iCount);
			DispatchKeyValue(iEnt, "targetname", sTargetname);
		}

		iCount++;
		gA_Triggers.Push(iEnt);
	}

	iCount = 1;

	while((iEnt = FindEntityByClassname(iEnt, "trigger_push")) != -1)
	{
		char sBuffer[128];
		GetEntPropString(iEnt, Prop_Send, "m_iName", sBuffer, 128, 0);

		if(strlen(sBuffer) == 0)
		{
			char sTargetname[64];
			FormatEx(sTargetname, 64, "trigger_push_#%d", iCount);
			DispatchKeyValue(iEnt, "targetname", sTargetname);
		}

		iCount++;
		gA_Triggers.Push(iEnt);
	}
}

public void OnMapStart()
{
	if(!gB_Connected)
	{
		return;
	}

	GetCurrentMap(gS_Map, 160);
	GetMapDisplayName(gS_Map, gS_Map, 160);

	gB_LinearMap = false;
	gI_MapZones = 0;
	gI_Bonuses = 0;
	gI_Stages = 1;
	gI_Checkpoints = 0;
	UnloadZones(0);
	FindTriggers();
	RefreshZones();
	LoadBonusZones();
	LoadStageZones();
	LoadCheckpointZones();
	
	LoadZoneSettings();

	InitTeleDestinations();
	
	PrecacheModel("models/props/cs_office/vending_machine.mdl");

	// draw
	// start drawing mapzones here
	if(gH_DrawEverything == null)
	{
		gH_DrawEverything = CreateTimer(gCV_Interval.FloatValue, Timer_DrawEverything, INVALID_HANDLE, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	}

	if(gB_Late)
	{
		chatstrings_t chatstrings;
		Shavit_GetChatStringsStruct(chatstrings);
		Shavit_OnChatConfigLoaded(chatstrings);
	}
}

void LoadBonusZones()
{
	char sQuery[256];
	FormatEx(sQuery, 256, "SELECT track FROM mapzones WHERE map = '%s' ORDER BY track DESC", gS_Map);
	gH_SQL.Query(SQL_GetBonusZone_Callback, sQuery, 0, DBPrio_High);
}

public void SQL_GetBonusZone_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (zones GetBonusZones) SQL query failed. Reason: %s", error);
		return;
	}

	if(results.FetchRow())
	{
		gI_Bonuses = results.FetchInt(0);
	}
}

void LoadStageZones()
{
	char sQuery[256];
	FormatEx(sQuery, 256, "SELECT id, data FROM mapzones WHERE type = %i and map = '%s'", Zone_Stage, gS_Map);
	gH_SQL.Query(SQL_GetStageZone_Callback, sQuery, 0, DBPrio_High);
}

public void SQL_GetStageZone_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (zones GetStageZone) SQL query failed. Reason: %s", error);
		return;
	}

	while(results.FetchRow())
	{
		gI_Stages = results.RowCount + 1;
	}

	gB_LinearMap = (gI_Stages == 1);

	Shavit_ReloadWRCPs();
}

void LoadCheckpointZones()
{
	char sQuery[256];
	FormatEx(sQuery, 256, "SELECT id, data FROM mapzones WHERE type = %i AND map = '%s'", Zone_Checkpoint, gS_Map);
	gH_SQL.Query(SQL_GetCheckpointZone_Callback, sQuery, 0, DBPrio_High);
}

public void SQL_GetCheckpointZone_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (zones GetCheckpointZone) SQL query failed. Reason: %s", error);
		return;
	}

	while(results.FetchRow())
	{
		gI_Checkpoints = results.RowCount;
	}

	Shavit_ReloadWRCheckpoints();
}

public void OnMapEnd()
{
	delete gH_DrawEverything;
}

public void Shavit_OnChatConfigLoaded(chatstrings_t strings)
{
	gS_ChatStrings = strings;
}

void ClearZone(int index)
{
	for(int i = 0; i < 3; i++)
	{
		gV_MapZones[index][0][i] = 0.0;
		gV_MapZones[index][1][i] = 0.0;
		gV_Destinations[index][i] = 0.0;
		gV_ZoneCenter[index][i] = 0.0;
	}

	gA_ZoneCache[index].bZoneInitialized = false;
	gA_ZoneCache[index].iZoneType = -1;
	gA_ZoneCache[index].iZoneTrack = -1;
	gA_ZoneCache[index].iEntityID = -1;
	gA_ZoneCache[index].iDatabaseID = -1;
	gA_ZoneCache[index].iZoneFlags = 0;
	gA_ZoneCache[index].iZoneData = 0;
}

void UnhookEntity(int entity)
{
	SDKUnhook(entity, SDKHook_StartTouchPost, StartTouchPost);
	SDKUnhook(entity, SDKHook_StartTouchPost, StartTouchPost_Bot);
	SDKUnhook(entity, SDKHook_EndTouchPost, EndTouchPost);
	SDKUnhook(entity, SDKHook_TouchPost, TouchPost);
}

void KillZoneEntity(int index)
{
	int entity = gA_ZoneCache[index].iEntityID;
	
	if(entity > MaxClients && IsValidEntity(entity))
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			for(int j = 0; j < TRACKS_SIZE; j++)
			{
				gB_InsideZone[i][gA_ZoneCache[index].iZoneType][j] = false;
			}

			gB_InsideZoneID[i][index] = false;
		}

		char sTargetname[32];
		GetEntPropString(entity, Prop_Data, "m_iName", sTargetname, 32);

		if(StrContains(sTargetname, "shavit_zones_") == -1)
		{
			return;
		}

		UnhookEntity(entity);
		AcceptEntityInput(entity, "Kill");
	}
}

// 0 - all zones
void UnloadZones(int zone)
{
	for(int i = 0; i < ZONETYPES_SIZE; i++)
	{
		gI_ZoneMaxData[i] = 0;
	}

	for(int i = 0; i < MAX_ZONES; i++)
	{
		if((zone == 0 || gA_ZoneCache[i].iZoneType == zone) && gA_ZoneCache[i].bZoneInitialized)
		{
			KillZoneEntity(i);
			ClearZone(i);
		}
	}

	if(zone == 0)
	{
		gB_ZonesCreated = false;

		char sTargetname[32];
		int iEntity = INVALID_ENT_REFERENCE;

		while((iEntity = FindEntityByClassname(iEntity, "trigger_multiple")) != INVALID_ENT_REFERENCE)
		{
			GetEntPropString(iEntity, Prop_Data, "m_iName", sTargetname, 32);

			if(StrContains(sTargetname, "shavit_") != -1)
			{
				AcceptEntityInput(iEntity, "Kill");
			}
		}
	}

	return;
}

void RefreshZones()
{
	char sQuery[512];
	FormatEx(sQuery, 512,
		"SELECT type, corner1_x, corner1_y, corner1_z, corner2_x, corner2_y, corner2_z, destination_x, destination_y, destination_z, track, %s, flags, data, hookname FROM %smapzones WHERE map = '%s';",
		(gB_MySQL)? "id":"rowid", gS_MySQLPrefix, gS_Map);

	gH_SQL.Query(SQL_RefreshZones_Callback, sQuery, 0, DBPrio_High);
}

public void SQL_RefreshZones_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (zone refresh) SQL query failed. Reason: %s", error);

		return;
	}

	gI_MapZones = 0;

	while(results.FetchRow())
	{
		int type = results.FetchInt(0);

		gV_MapZones[gI_MapZones][0][0] = gV_MapZones_Visual[gI_MapZones][0][0] = results.FetchFloat(1);
		gV_MapZones[gI_MapZones][0][1] = gV_MapZones_Visual[gI_MapZones][0][1] = results.FetchFloat(2);
		gV_MapZones[gI_MapZones][0][2] = gV_MapZones_Visual[gI_MapZones][0][2] = results.FetchFloat(3);
		gV_MapZones[gI_MapZones][1][0] = gV_MapZones_Visual[gI_MapZones][7][0] = results.FetchFloat(4);
		gV_MapZones[gI_MapZones][1][1] = gV_MapZones_Visual[gI_MapZones][7][1] = results.FetchFloat(5);
		gV_MapZones[gI_MapZones][1][2] = gV_MapZones_Visual[gI_MapZones][7][2] = results.FetchFloat(6);

		CreateZonePoints(gV_MapZones_Visual[gI_MapZones], gCV_Offset.FloatValue);

		gV_ZoneCenter[gI_MapZones][0] = (gV_MapZones[gI_MapZones][0][0] + gV_MapZones[gI_MapZones][1][0]) / 2.0;
		gV_ZoneCenter[gI_MapZones][1] = (gV_MapZones[gI_MapZones][0][1] + gV_MapZones[gI_MapZones][1][1]) / 2.0;
		gV_ZoneCenter[gI_MapZones][2] = (gV_MapZones[gI_MapZones][0][2] + gV_MapZones[gI_MapZones][1][2]) / 2.0;

		if(type == Zone_Teleport || type == Zone_Stage)
		{
			gV_Destinations[gI_MapZones][0] = results.FetchFloat(7);
			gV_Destinations[gI_MapZones][1] = results.FetchFloat(8);
			gV_Destinations[gI_MapZones][2] = results.FetchFloat(9);
		}

		gA_ZoneCache[gI_MapZones].bZoneInitialized = true;
		gA_ZoneCache[gI_MapZones].iZoneType = type;
		gA_ZoneCache[gI_MapZones].iZoneTrack = results.FetchInt(10);
		gA_ZoneCache[gI_MapZones].iDatabaseID = results.FetchInt(11);
		gA_ZoneCache[gI_MapZones].iZoneFlags = results.FetchInt(12);
		gA_ZoneCache[gI_MapZones].iZoneData = results.FetchInt(13);
		gI_ZoneMaxData[type] = results.FetchInt(13);
		results.FetchString(14, gA_ZoneCache[gI_MapZones].sZoneHookname, 128);
		gA_ZoneCache[gI_MapZones].iEntityID = -1;

		gI_MapZones++;
	}

	CreateZoneEntities();
}

public void OnClientPutInServer(int client)
{
	for(int i = 0; i < TRACKS_SIZE; i++)
	{
		for(int j = 0; j < ZONETYPES_SIZE; j++)
		{
			gB_InsideZone[client][j][i] = false;
		}
	}

	for(int i = 0; i < MAX_ZONES; i++)
	{
		gB_InsideZoneID[client][i] = false;
	}
	gB_ZoneDataInput[client] = false;
	gB_CommandToEdit[client] = false;
	gB_ShowTriggers[client] = false;

	Reset(client);
}

public void OnClientDisconnect_Post(int client)
{
	gB_ShowTriggers[client] = false;
	transmitTriggers(client, false);
}

public Action Command_Modifier(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if(args == 0)
	{
		Shavit_PrintToChat(client, "%T", "ModifierCommandNoArgs", client);

		return Plugin_Handled;
	}

	char sArg1[16];
	GetCmdArg(1, sArg1, 16);

	float fArg1 = StringToFloat(sArg1);

	if(fArg1 <= 0.0)
	{
		Shavit_PrintToChat(client, "%T", "ModifierTooLow", client);

		return Plugin_Handled;
	}

	gF_Modifier[client] = fArg1;

	Shavit_PrintToChat(client, "%T %s%.01f%s.", "ModifierSet", client, gS_ChatStrings.sVariable, fArg1, gS_ChatStrings.sText);

	return Plugin_Handled;
}

public Action Command_ZoneEdit(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	Reset(client);
	gB_CommandToEdit[client] = true;

	OpenEditMenu(client);

	return Plugin_Handled;
}

public Action Command_ReloadZoneSettings(int client, int args)
{
	LoadZoneSettings();

	ReplyToCommand(client, "Reloaded zone settings.");

	return Plugin_Handled;
}

public Action Command_Test(int client, int args)
{
	
	return Plugin_Handled;
}

public Action Command_Back(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if(!IsPlayerAlive(client))
	{
		Shavit_PrintToChat(client, "%T", "StageCommandAlive", client, gS_ChatStrings.sVariable2, gS_ChatStrings.sText);

		return Plugin_Handled;
	}

	if(!EmptyVector(gV_Destinations[gI_InsideZoneIndex[client]]))
	{
		TeleportEntity(client, gV_Destinations[gI_InsideZoneIndex[client]], NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	}

	else
	{
		TeleportEntity(client, gV_ZoneCenter[gI_InsideZoneIndex[client]], gV_ZoneCenter_Angle[gI_InsideZoneIndex[client]], view_as<float>({0.0, 0.0, 0.0}));
	}

	return Plugin_Handled;
}

public Action Command_Stages(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if(!IsPlayerAlive(client))
	{
		Shavit_PrintToChat(client, "%T", "StageCommandAlive", client, gS_ChatStrings.sVariable2, gS_ChatStrings.sText);

		return Plugin_Handled;
	}

	int iStage = -1;
	char sCommand[16];
	GetCmdArg(0, sCommand, 16);

	if ('0' <= sCommand[4] <= '9')
	{
		iStage = sCommand[4] - '0';
	}
	else if (args > 0)
	{
		char arg1[8];
		GetCmdArg(1, arg1, 8);
		iStage = StringToInt(arg1);
	}

	if (iStage > -1)
	{
		if(iStage == 1)
		{
			FakeClientCommand(client, "sm_r");
			return Plugin_Handled;
		}

		for(int i = 0; i < gI_MapZones; i++)
		{
			if(gA_ZoneCache[i].bZoneInitialized && gA_ZoneCache[i].iZoneType == Zone_Stage && gA_ZoneCache[i].iZoneData == iStage)
			{
				Shavit_StopTimer(client);
				gB_SingleStageTiming[client] = true;

				if(!EmptyVector(gV_Destinations[i]))
				{
					TeleportEntity(client, gV_Destinations[i], NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
				}

				else
				{
					TeleportEntity(client, gV_ZoneCenter[i], NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
				}
			}
		}
	}
	else
	{
		Menu menu = new Menu(MenuHandler_SelectStage);
		menu.SetTitle("%T", "ZoneMenuStage", client);

		char sDisplay[64];
	
		for(int i = 0; i < gI_MapZones; i++)
		{
			if(gA_ZoneCache[i].bZoneInitialized && gA_ZoneCache[i].iZoneType == Zone_Stage)
			{
				char sTrack[32];
				GetTrackName(client, gA_ZoneCache[i].iZoneTrack, sTrack, 32);
	
				FormatEx(sDisplay, 64, "#%d - (%s)", (i + 1), gA_ZoneCache[i].iZoneData, sTrack);
	
				char sInfo[8];
				IntToString(i, sInfo, 8);
	
				menu.AddItem(sInfo, sDisplay);
			}
		}

		menu.Display(client, MENU_TIME_FOREVER);
	}

	return Plugin_Handled;
}

public int MenuHandler_SelectStage(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);
		int iIndex = StringToInt(sInfo);
		
		Shavit_StopTimer(param1);
		gB_SingleStageTiming[param1] = true;

		if(!EmptyVector(gV_Destinations[iIndex]))
		{
			TeleportEntity(param1, gV_Destinations[iIndex], NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		}

		else
		{
			TeleportEntity(param1, gV_ZoneCenter[iIndex], NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		}
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

public Action Command_Showzones(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}
	
	gB_ShowTriggers[client] = !gB_ShowTriggers[client];
	
	if(gB_ShowTriggers[client])
	{
		Shavit_PrintToChat(client, "Showing zones.");
	}
	else
	{
		Shavit_PrintToChat(client, "Stopped showing zones.");
	}
	
	transmitTriggers(client, gB_ShowTriggers[client]);

	return Plugin_Handled;
}

public Action Command_HookZones(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if(!IsPlayerAlive(client))
	{
		Shavit_PrintToChat(client, "%T", "ZonesCommand", client, gS_ChatStrings.sWarning, gS_ChatStrings.sText);

		return Plugin_Handled;
	}

	OpenHookZonesMenu_SelectMethod(client);

	return Plugin_Handled;
}

void OpenHookZonesMenu_SelectMethod(int client)
{
	Reset(client);

	Menu menu = new Menu(HookZoneMenuHandler_SelectMethod);
	menu.SetTitle("%T", "HookZoneSelectMethod", client);

	menu.AddItem("", "Name");
	menu.AddItem("", "Origin");

	menu.Display(client, -1);
}

public int HookZoneMenuHandler_SelectMethod(Menu a, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		Menu menu = new Menu(MenuHandler_BeforeSelectHookZone);
		menu.SetTitle("%T", "HookZoneMenuTrigger", param1);

		switch(param2)
		{
			case 0:
			{
				for(int i = 0; i < gA_Triggers.Length; i++)
				{
					int iEnt = gA_Triggers.Get(i);
					
					char sTriggerName[128];
					GetEntPropString(iEnt, Prop_Send, "m_iName", sTriggerName, 128, 0);
					menu.AddItem(sTriggerName, sTriggerName);
				}
			}

			case 1:
			{
				for(int i = 0; i < gA_Triggers.Length; i++)
				{
					int iEnt = gA_Triggers.Get(i);

					float origin[3];
					GetEntPropVector(iEnt, Prop_Send, "m_vecOrigin", origin);

					char sBuffer[128];
					FormatEx(sBuffer, 128, "%.2f %.2f %.2f", origin[0], origin[1], origin[2]);
					menu.AddItem("", sBuffer);
				}
			}
		}

		menu.ExitBackButton = true;
		menu.Display(param1, -1);
	}

	else if(action == MenuAction_End)
	{
		delete a;
	}

	return 0;
}

public int MenuHandler_BeforeSelectHookZone(Menu a, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		gI_HookZoneIndex[param1] = gA_Triggers.Get(param2);

		Menu menu = new Menu(MenuHandler_SelectHookZone);
		menu.SetTitle("%T", "HookZoneMenuBefore", param1);

		menu.AddItem("", "Teleport To");
		menu.AddItem("", "Hook zone");

		menu.ExitBackButton = true;
		menu.Display(param1, -1);
	}

	else if(action == MenuAction_Cancel)
	{
		OpenHookZonesMenu_SelectMethod(param1);
	}

	else if(action == MenuAction_End)
	{
		delete a;
	}

	return 0;
}

public int MenuHandler_SelectHookZone(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		int iEnt = gI_HookZoneIndex[param1];
		char sHookname[128];
		GetEntPropString(iEnt, Prop_Send, "m_iName", sHookname, 128, 0);
		float origin[3];
		GetEntPropVector(iEnt, Prop_Send, "m_vecOrigin", origin);

		switch(param2)
		{
			case 0:
			{
				TeleportEntity(param1, origin, NULL_VECTOR, NULL_VECTOR);
				Shavit_PrintToChat(param1, "%T", "HookTeleportZonesItem", param1, sHookname);
				menu.Display(param1, -1);
			}

			case 1:
			{
				strcopy(gS_ZoneHookname[param1], 128, sHookname);
				Shavit_PrintToChat(param1, "%T", "HookZonesItem", param1, sHookname);

				float fMins[3], fMaxs[3];
				GetEntPropVector(iEnt, Prop_Send, "m_vecMins", fMins);
				GetEntPropVector(iEnt, Prop_Send, "m_vecMaxs", fMaxs);

				for (int j = 0; j < 3; j++)
				{
					fMins[j] = (fMins[j] + origin[j]);
				}

				for (int j = 0; j < 3; j++)
				{
					fMaxs[j] = (fMaxs[j] + origin[j]);
				}

				gV_Point1[param1][0] = fMins[0];
				gV_Point1[param1][1] = fMins[1];
				gV_Point1[param1][2] = fMins[2];
				gV_Point2[param1][0] = fMaxs[0];
				gV_Point2[param1][1] = fMaxs[1];
				gV_Point2[param1][2] = fMaxs[2];

				OpenHookZonesMenu_Track(param1);
			}
		}
	}

	else if(action == MenuAction_Cancel)
	{
		OpenHookZonesMenu_SelectMethod(param1);
	}
}

void OpenHookZonesMenu_Track(int client)
{
	Menu menu = new Menu(MenuHandler_SelectHookZone_Track);
	menu.SetTitle("%T", "ZoneMenuTrack", client);

	for(int i = 0; i < TRACKS_SIZE; i++)
	{
		char sInfo[8];
		IntToString(i, sInfo, 8);

		char sDisplay[16];
		GetTrackName(client, i, sDisplay, 16);

		menu.AddItem(sInfo, sDisplay);
	}

	menu.ExitBackButton = true;
	menu.Display(client, 300);
}

public int MenuHandler_SelectHookZone_Track(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);
		gI_ZoneTrack[param1] = StringToInt(sInfo);

		char sTrack[16];
		GetTrackName(param1, gI_ZoneTrack[param1], sTrack, 16);

		Menu submenu = new Menu(MenuHandler_SelectHookZone_Type);
		submenu.SetTitle("%T\n ", "ZoneMenuTitle", param1, sTrack);

		for(int i = 0; i < sizeof(gS_ZoneNames); i++)
		{
			if(StrEqual(gS_ZoneNames[i], "Stage Zone") && gI_Checkpoints > 0)
			{
				continue;
			}

			else if(StrEqual(gS_ZoneNames[i], "Checkpoint Zone") && gI_Stages > 1)
			{
				continue;
			}

			IntToString(i, sInfo, 8);
			submenu.AddItem(sInfo, gS_ZoneNames[i]);
		}

		submenu.Display(param1, 300);
	}

	else if(action == MenuAction_Cancel)
	{
		OpenHookZonesMenu_SelectMethod(param1);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

public int MenuHandler_SelectHookZone_Type(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, 8);

		gI_ZoneType[param1] = StringToInt(info);

		HookZoneConfirmMenu(param1);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void HookZoneConfirmMenu(int client)
{
	char sTrack[32];
	GetTrackName(client, gI_ZoneTrack[client], sTrack, 32);

	Menu menu = new Menu(HookZoneConfirm_Handler);
	menu.SetTitle("%T\n%T\n ", "ZoneEditConfirm", client, "ZoneEditTrack", client, sTrack);

	char sMenuItem[64];

	FormatEx(sMenuItem, 64, "%T", "ZoneSetYes", client);
	menu.AddItem("yes", sMenuItem);

	FormatEx(sMenuItem, 64, "%T", "ZoneSetNo", client);
	menu.AddItem("no", sMenuItem);

	if(!gB_ZoneDataInput[client] && !gB_CommandToEdit[client])
	{
		gI_ZoneData[client][gI_ZoneType[client]] = gI_ZoneMaxData[gI_ZoneType[client]] + 1;

		if(gI_ZoneType[client] == Zone_Stage)
		{
			gI_ZoneData[client][gI_ZoneType[client]] = gI_Stages + 1;
		}
	}
	gB_ZoneDataInput[client] = false;
	gB_CommandToEdit[client] = false;

	FormatEx(sMenuItem, 64, "%T", "ZoneSetData", client, gI_ZoneData[client][gI_ZoneType[client]]);
	menu.AddItem("datafromchat", sMenuItem);

	menu.ExitButton = false;
	menu.Display(client, -1);
}

public int HookZoneConfirm_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, 16);

		if(StrEqual(sInfo, "yes"))
		{
			InsertZone(param1);
		}

		else if(StrEqual(sInfo, "no"))
		{
			OpenHookZonesMenu_SelectMethod(param1);
		}

		else if(StrEqual(sInfo, "datafromchat"))
		{
			gB_WaitingForChatInput[param1] = true;
			gB_HookZoneConfirm[param1] = true;

			Shavit_PrintToChat(param1, "%T", "ZoneEnterDataChat", param1);

			return 0;
		}
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public Action Command_Zones(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	if(!IsPlayerAlive(client))
	{
		Shavit_PrintToChat(client, "%T", "ZonesCommand", client, gS_ChatStrings.sWarning, gS_ChatStrings.sText);

		return Plugin_Handled;
	}

	OpenZonesMenu(client);

	return Plugin_Handled;
}

void OpenZonesMenu(int client)
{
	Reset(client);

	Menu menu = new Menu(MenuHandler_SelectZoneTrack);
	menu.SetTitle("%T", "ZoneMenuTrack", client);

	for(int i = 0; i < TRACKS_SIZE; i++)
	{
		char sInfo[8];
		IntToString(i, sInfo, 8);

		char sDisplay[16];
		GetTrackName(client, i, sDisplay, 16);

		menu.AddItem(sInfo, sDisplay);
	}

	menu.Display(client, 300);
}

public int MenuHandler_SelectZoneTrack(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[8];
		menu.GetItem(param2, sInfo, 8);
		gI_ZoneTrack[param1] = StringToInt(sInfo);

		char sTrack[16];
		GetTrackName(param1, gI_ZoneTrack[param1], sTrack, 16);

		Menu submenu = new Menu(MenuHandler_SelectZoneType);
		submenu.SetTitle("%T\n ", "ZoneMenuTitle", param1, sTrack);

		for(int i = 0; i < sizeof(gS_ZoneNames); i++)
		{
			if(StrEqual(gS_ZoneNames[i], "Stage Zone") && gI_Checkpoints > 0)
			{
				continue;
			}

			else if(StrEqual(gS_ZoneNames[i], "Checkpoint Zone") && gI_Stages > 1)
			{
				continue;
			}

			IntToString(i, sInfo, 8);
			submenu.AddItem(sInfo, gS_ZoneNames[i]);
		}

		submenu.Display(param1, 300);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}
	
	return 0;
}

public int MenuHandler_SelectZoneType(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, 8);

		gI_ZoneType[param1] = StringToInt(info);

		ShowPanel(param1, 1);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void OpenEditMenu(int client)
{
	Reset(client);

	Menu menu = new Menu(MenuHandler_ZoneEdit);
	menu.SetTitle("%T\n ", "ZoneEditTitle", client);

	char sDisplay[64];
	FormatEx(sDisplay, 64, "%T", "ZoneEditRefresh", client);
	menu.AddItem("-2", sDisplay);

	for(int i = 0; i < gI_MapZones; i++)
	{
		if(!gA_ZoneCache[i].bZoneInitialized)
		{
			continue;
		}

		char sInfo[8];
		IntToString(i, sInfo, 8);

		char sTrack[32];
		GetTrackName(client, gA_ZoneCache[i].iZoneTrack, sTrack, 32);

		FormatEx(sDisplay, 64, "#%d - %s %d (%s)", (i + 1), gS_ZoneNames[gA_ZoneCache[i].iZoneType], gA_ZoneCache[i].iZoneData, sTrack);

		if(gB_InsideZoneID[client][i])
		{
			Format(sDisplay, 64, "%s %T", sDisplay, "ZoneInside", client);
		}

		menu.AddItem(sInfo, sDisplay);
	}

	if(menu.ItemCount == 0)
	{
		FormatEx(sDisplay, 64, "%T", "ZonesMenuNoneFound", client);
		menu.AddItem("-1", sDisplay);
	}

	menu.Display(client, 300);
}

public int MenuHandler_ZoneEdit(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, 8);

		int id = StringToInt(info);

		switch(id)
		{
			case -2:
			{
				OpenEditMenu(param1);
			}

			case -1:
			{
				Shavit_PrintToChat(param1, "%T", "ZonesMenuNoneFound", param1);
			}

			default:
			{
				// a hack to place the player in the last step of zone editing
				gI_MapStep[param1] = 3;
				gV_Point1[param1] = gV_MapZones[id][0];
				gV_Point2[param1] = gV_MapZones[id][1];
				gI_ZoneType[param1] = gA_ZoneCache[id].iZoneType;
				gI_ZoneTrack[param1] = gA_ZoneCache[id].iZoneTrack;
				gV_Teleport[param1] = gV_Destinations[id];
				gI_ZoneDatabaseID[param1] = gA_ZoneCache[id].iDatabaseID;
				gI_ZoneFlags[param1] = gA_ZoneCache[id].iZoneFlags;
				gI_ZoneData[param1][gI_ZoneType[param1]] = gA_ZoneCache[id].iZoneData;//zoneid change start here
				gI_ZoneID[param1] = id;

				// to stop the original zone from drawing
				gA_ZoneCache[id].bZoneInitialized = false;

				// draw the zone edit
				CreateTimer(0.1, Timer_Draw, GetClientSerial(param1), TIMER_REPEAT);

				CreateEditMenu(param1);
			}
		}

		gB_CommandToEdit[param1] = false;
		RefreshZones();
		LoadStageZones();
		LoadCheckpointZones();
	}

	else if(action == MenuAction_Cancel)
	{
		gB_CommandToEdit[param1] = false;
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public Action Command_DeleteZone(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	return OpenDeleteMenu(client);
}

Action OpenDeleteMenu(int client)
{
	Menu menu = new Menu(MenuHandler_DeleteZone);
	menu.SetTitle("%T\n ", "ZoneMenuDeleteTitle", client);

	char sDisplay[64];
	FormatEx(sDisplay, 64, "%T", "ZoneEditRefresh", client);
	menu.AddItem("-2", sDisplay);

	for(int i = 0; i < gI_MapZones; i++)
	{
		if(gA_ZoneCache[i].bZoneInitialized)
		{
			char sTrack[32];
			GetTrackName(client, gA_ZoneCache[i].iZoneTrack, sTrack, 32);

			FormatEx(sDisplay, 64, "#%d - %s %d (%s)", (i + 1), gS_ZoneNames[gA_ZoneCache[i].iZoneType], gA_ZoneCache[i].iZoneData, sTrack);

			char sInfo[8];
			IntToString(i, sInfo, 8);
			
			if(gB_InsideZoneID[client][i])
			{
				Format(sDisplay, 64, "%s %T", sDisplay, "ZoneInside", client);
			}

			menu.AddItem(sInfo, sDisplay);
		}
	}

	if(menu.ItemCount == 0)
	{
		char sMenuItem[64];
		FormatEx(sMenuItem, 64, "%T", "ZonesMenuNoneFound", client);
		menu.AddItem("-1", sMenuItem);
	}

	menu.Display(client, -1);

	return Plugin_Handled;
}

public int MenuHandler_DeleteZone(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, 8);

		int id = StringToInt(info);
	
		switch(id)
		{
			case -2:
			{
				OpenDeleteMenu(param1);
			}

			case -1:
			{
				Shavit_PrintToChat(param1, "%T", "ZonesMenuNoneFound", param1);
			}

			default:
			{
				Shavit_LogMessage("%L - deleted %s (id %d) from map `%s`.", param1, gS_ZoneNames[gA_ZoneCache[id].iZoneType], gA_ZoneCache[id].iDatabaseID, gS_Map);
				
				char sQuery[256];
				FormatEx(sQuery, 256, "DELETE FROM %smapzones WHERE %s = %d;", gS_MySQLPrefix, (gB_MySQL)? "id":"rowid", gA_ZoneCache[id].iDatabaseID);

				DataPack hDatapack = new DataPack();
				hDatapack.WriteCell(GetClientSerial(param1));
				hDatapack.WriteCell(gA_ZoneCache[id].iZoneType);

				gH_SQL.Query(SQL_DeleteZone_Callback, sQuery, hDatapack);
			}
		}
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public void SQL_DeleteZone_Callback(Database db, DBResultSet results, const char[] error, DataPack data)
{
	data.Reset();
	int client = GetClientFromSerial(data.ReadCell());
	int type = data.ReadCell();

	delete data;

	if(results == null)
	{
		LogError("Timer (single zone delete) SQL query failed. Reason: %s", error);

		return;
	}

	if(client == 0)
	{
		return;
	}

	UnloadZones(type);
	RefreshZones();
	LoadStageZones();
	LoadCheckpointZones();

	Shavit_PrintToChat(client, "%T", "ZoneDeleteSuccessful", client, gS_ChatStrings.sVariable, gS_ZoneNames[type], gS_ChatStrings.sText);
	CreateTimer(0.05, Timer_OpenDeleteMenu, client);
}

public Action Timer_OpenDeleteMenu(Handle timer, int client)
{
	OpenDeleteMenu(client);

	return Plugin_Handled;
}

public Action Command_DeleteAllZones(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_DeleteAllZones);
	menu.SetTitle("%T", "ZoneMenuDeleteALLTitle", client);

	char sMenuItem[64];

	for(int i = 1; i <= GetRandomInt(1, 4); i++)
	{
		FormatEx(sMenuItem, 64, "%T", "ZoneMenuNo", client);
		menu.AddItem("-1", sMenuItem);
	}

	FormatEx(sMenuItem, 64, "%T", "ZoneMenuYes", client);
	menu.AddItem("yes", sMenuItem);

	for(int i = 1; i <= GetRandomInt(1, 3); i++)
	{
		FormatEx(sMenuItem, 64, "%T", "ZoneMenuNo", client);
		menu.AddItem("-1", sMenuItem);
	}

	menu.Display(client, 300);

	return Plugin_Handled;
}

public int MenuHandler_DeleteAllZones(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(param2, info, 8);

		int iInfo = StringToInt(info);

		if(iInfo == -1)
		{
			return;
		}

		Shavit_LogMessage("%L - deleted all zones from map `%s`.", param1, gS_Map);

		char sQuery[256];
		FormatEx(sQuery, 256, "DELETE FROM %smapzones WHERE map = '%s';", gS_MySQLPrefix, gS_Map);

		gH_SQL.Query(SQL_DeleteAllZones_Callback, sQuery, GetClientSerial(param1));
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}
}

public void SQL_DeleteAllZones_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (single zone delete) SQL query failed. Reason: %s", error);

		return;
	}

	UnloadZones(0);

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	Shavit_PrintToChat(client, "%T", "ZoneDeleteAllSuccessful", client);
}

void Reset(int client)
{
	gI_ZoneTrack[client] = Track_Main;
	gF_Modifier[client] = 16.0;
	gI_MapStep[client] = 0;
	gI_GridSnap[client] = 16;
	gB_SnapToWall[client] = false;
	gB_CursorTracing[client] = true;
	gI_ZoneFlags[client] = 0;
	gI_ZoneDatabaseID[client] = -1;
	gB_WaitingForChatInput[client] = false;
	gB_HookZoneConfirm[client] = false;
	strcopy(gS_ZoneHookname[client], 128, "NONE");
	gI_ZoneID[client] = -1;
	gI_LastStage[client] = 1;
	gI_LastCheckpoint[client] = (gB_LinearMap) ? 0 : 1;
	gB_IntoStage[client] = false;
	gB_IntoCheckpoint[client] = false;

	for(int i = 0; i < 3; i++)
	{
		gV_Point1[client][i] = 0.0;
		gV_Point2[client][i] = 0.0;
		gV_Teleport[client][i] = 0.0;
		gV_WallSnap[client][i] = 0.0;
	}

	for(int i = 0; i < ZONETYPES_SIZE; i++)
	{
		gI_ZoneData[client][i] = 0;
	}
}

void ShowPanel(int client, int step)
{
	gI_MapStep[client] = step;

	if(step == 1)
	{
		CreateTimer(0.1, Timer_Draw, GetClientSerial(client), TIMER_REPEAT);
	}

	Panel pPanel = new Panel();

	char sPanelText[128];
	char sFirst[64];
	char sSecond[64];
	FormatEx(sFirst, 64, "%T", "ZoneFirst", client);
	FormatEx(sSecond, 64, "%T", "ZoneSecond", client);

	FormatEx(sPanelText, 128, "%T", "ZonePlaceText", client, (step == 1)? sFirst:sSecond);

	pPanel.DrawItem(sPanelText, ITEMDRAW_RAWLINE);
	char sPanelItem[64];
	FormatEx(sPanelItem, 64, "%T", "AbortZoneCreation", client);
	pPanel.DrawItem(sPanelItem);

	char sDisplay[64];
	FormatEx(sDisplay, 64, "%T", "GridSnapPlus", client, gI_GridSnap[client]);
	pPanel.DrawItem(sDisplay);

	FormatEx(sDisplay, 64, "%T", "GridSnapMinus", client);
	pPanel.DrawItem(sDisplay);

	FormatEx(sDisplay, 64, "%T", "WallSnap", client, (gB_SnapToWall[client])? "ZoneSetYes":"ZoneSetNo", client);
	pPanel.DrawItem(sDisplay);

	FormatEx(sDisplay, 64, "%T", "CursorZone", client, (gB_CursorTracing[client])? "ZoneSetYes":"ZoneSetNo", client);
	pPanel.DrawItem(sDisplay);

	pPanel.Send(client, ZoneCreation_Handler, 600);

	delete pPanel;
}

public int ZoneCreation_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		switch(param2)
		{
			case 1:
			{
				Reset(param1);

				return 0;
			}

			case 2:
			{
				gI_GridSnap[param1] *= 2;

				if(gI_GridSnap[param1] > 64)
				{
					gI_GridSnap[param1] = 1;
				}
			}

			case 3:
			{
				gI_GridSnap[param1] /= 2;

				if(gI_GridSnap[param1] < 1)
				{
					gI_GridSnap[param1] = 64;
				}
			}

			case 4:
			{
				gB_SnapToWall[param1] = !gB_SnapToWall[param1];

				if(gB_SnapToWall[param1])
				{
					gB_CursorTracing[param1] = false;

					if(gI_GridSnap[param1] < 32)
					{
						gI_GridSnap[param1] = 32;
					}
				}
			}

			case 5:
			{
				gB_CursorTracing[param1] = !gB_CursorTracing[param1];

				if(gB_CursorTracing[param1])
				{
					gB_SnapToWall[param1] = false;
				}
			}
		}
		
		ShowPanel(param1, gI_MapStep[param1]);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

float[] SnapToGrid(float pos[3], int grid, bool third)
{
	float origin[3];
	origin = pos;

	origin[0] = float(RoundToNearest(pos[0] / grid) * grid);
	origin[1] = float(RoundToNearest(pos[1] / grid) * grid);
	
	if(third)
	{
		origin[2] = float(RoundToNearest(pos[2] / grid) * grid);
	}

	return origin;
}

bool SnapToWall(float pos[3], int client, float final[3])
{
	bool hit = false;

	float end[3];
	float temp[3];

	float prefinal[3];
	prefinal = pos;

	for(int i = 0; i < 4; i++)
	{
		end = pos;

		int axis = (i / 2);
		end[axis] += (((i % 2) == 1)? -gI_GridSnap[client]:gI_GridSnap[client]);

		TR_TraceRayFilter(pos, end, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilter_NoClients, client);

		if(TR_DidHit())
		{
			TR_GetEndPosition(temp);
			prefinal[axis] = temp[axis];
			hit = true;
		}
	}

	if(hit && GetVectorDistance(prefinal, pos) <= gI_GridSnap[client])
	{
		final = SnapToGrid(prefinal, gI_GridSnap[client], false);

		return true;
	}

	return false;
}

public bool TraceFilter_NoClients(int entity, int contentsMask, any data)
{
	return (entity != data && !IsValidClient(data));
}

float[] GetAimPosition(int client)
{
	float pos[3];
	GetClientEyePosition(client, pos);

	float angles[3];
	GetClientEyeAngles(client, angles);

	TR_TraceRayFilter(pos, angles, MASK_PLAYERSOLID, RayType_Infinite, TraceFilter_NoClients, client);

	if(TR_DidHit())
	{
		float end[3];
		TR_GetEndPosition(end);

		return SnapToGrid(end, gI_GridSnap[client], true);
	}

	return pos;
}

public bool TraceFilter_World(int entity, int contentsMask)
{
	return (entity == 0);
}

public Action Shavit_OnUserCmdPre(int client, int &buttons, int &impulse, float vel[3], float angles[3], TimerStatus status, int track, int style)
{
	if(gI_MapStep[client] > 0 && gI_MapStep[client] != 3)
	{
		int button = IN_USE;

		if((buttons & button) > 0)
		{
			if(!gB_Button[client])
			{
				float vPlayerOrigin[3];
				GetClientAbsOrigin(client, vPlayerOrigin);

				float origin[3];

				if(gB_CursorTracing[client])
				{
					origin = GetAimPosition(client);
				}

				else if(!(gB_SnapToWall[client] && SnapToWall(vPlayerOrigin, client, origin)))
				{
					origin = SnapToGrid(vPlayerOrigin, gI_GridSnap[client], false);
				}

				else
				{
					gV_WallSnap[client] = origin;
				}

				origin[2] = vPlayerOrigin[2];

				if(gI_MapStep[client] == 1)
				{
					gV_Point1[client] = origin;
					gV_Point1[client][2] += 1.0;

					ShowPanel(client, 2);
				}

				else if(gI_MapStep[client] == 2)
				{
					origin[2] += gCV_Height.FloatValue;
					gV_Point2[client] = origin;

					gI_MapStep[client]++;

					CreateEditMenu(client);
				}
			}

			gB_Button[client] = true;
		}

		else
		{
			gB_Button[client] = false;
		}
	}

	return Plugin_Continue;
}

public bool TRFilter_NoPlayers(int entity, int mask, any data)
{
	return (entity != view_as<int>(data) || (entity < 1 || entity > MaxClients));
}

public int CreateZoneConfirm_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, 16);

		if(StrEqual(sInfo, "yes"))
		{
			InsertZone(param1);
			gI_MapStep[param1] = 0;

			return 0;
		}

		else if(StrEqual(sInfo, "no"))
		{
			Reset(param1);

			return 0;
		}

		else if(StrEqual(sInfo, "adjust"))
		{
			CreateAdjustMenu(param1, 0);

			return 0;
		}

		else if(StrEqual(sInfo, "tpzone"))
		{
			UpdateTeleportZone(param1);
		}

		else if(StrEqual(sInfo, "datafromchat"))
		{
			gB_WaitingForChatInput[param1] = true;

			Shavit_PrintToChat(param1, "%T", "ZoneEnterDataChat", param1);

			return 0;
		}

		else if(StrEqual(sInfo, "forcerender"))
		{
			gI_ZoneFlags[param1] ^= ZF_ForceRender;
		}

		CreateEditMenu(param1);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if((gB_WaitingForChatInput[client] && gI_MapStep[client] == 3) || gB_HookZoneConfirm[client])
	{
		gI_ZoneData[client][gI_ZoneType[client]] = StringToInt(sArgs);
		gB_ZoneDataInput[client] = true;

		if(gB_HookZoneConfirm[client])
		{
			HookZoneConfirmMenu(client);
			return Plugin_Handled;
		}

		CreateEditMenu(client);

		return Plugin_Handled;
	}

	return Plugin_Continue;
}

void UpdateTeleportZone(int client)
{
	float vTeleport[3];
	GetClientAbsOrigin(client, vTeleport);
	vTeleport[2] += 2.0;

	if(gI_ZoneType[client] == Zone_Stage)
	{
		gV_Teleport[client] = vTeleport;

		Shavit_PrintToChat(client, "%T", "ZoneTeleportUpdated", client);
	}

	else
	{
		bool bInside = true;

		for(int i = 0; i < 3; i++)
		{
			if(gV_Point1[client][i] >= vTeleport[i] == gV_Point2[client][i] >= vTeleport[i])
			{
				bInside = false;
			}
		}

		if(bInside)
		{
			Shavit_PrintToChat(client, "%T", "ZoneTeleportInsideZone", client);
		}

		else
		{
			gV_Teleport[client] = vTeleport;

			Shavit_PrintToChat(client, "%T", "ZoneTeleportUpdated", client);
		}
	}
}

void CreateEditMenu(int client)
{
	char sTrack[32];
	GetTrackName(client, gI_ZoneTrack[client], sTrack, 32);

	Menu menu = new Menu(CreateZoneConfirm_Handler);
	menu.SetTitle("%T\n%T\n ", "ZoneEditConfirm", client, "ZoneEditTrack", client, sTrack);

	char sMenuItem[64];

	if(gI_ZoneType[client] == Zone_Teleport)
	{
		if(EmptyVector(gV_Teleport[client]))
		{
			FormatEx(sMenuItem, 64, "%T", "ZoneSetTP", client);
			menu.AddItem("-1", sMenuItem, ITEMDRAW_DISABLED);
		}

		else
		{
			FormatEx(sMenuItem, 64, "%T", "ZoneSetYes", client);
			menu.AddItem("yes", sMenuItem);
		}

		FormatEx(sMenuItem, 64, "%T", "ZoneSetTPZone", client);
		menu.AddItem("tpzone", sMenuItem);
	}

	else if(gI_ZoneType[client] == Zone_Stage)
	{
		FormatEx(sMenuItem, 64, "%T", "ZoneSetYes", client);
		menu.AddItem("yes", sMenuItem);

		FormatEx(sMenuItem, 64, "%T", "ZoneSetTPZone", client);
		menu.AddItem("tpzone", sMenuItem);
	}

	else
	{
		FormatEx(sMenuItem, 64, "%T", "ZoneSetYes", client);
		menu.AddItem("yes", sMenuItem);
	}

	FormatEx(sMenuItem, 64, "%T", "ZoneSetNo", client);
	menu.AddItem("no", sMenuItem);

	FormatEx(sMenuItem, 64, "%T", "ZoneSetAdjust", client);
	menu.AddItem("adjust", sMenuItem);

	FormatEx(sMenuItem, 64, "%T", "ZoneForceRender", client, ((gI_ZoneFlags[client] & ZF_ForceRender) > 0)? "＋":"－");
	menu.AddItem("forcerender", sMenuItem);

	if(!gB_ZoneDataInput[client] && !gB_CommandToEdit[client])
	{
		gI_ZoneData[client][gI_ZoneType[client]] = gI_ZoneMaxData[gI_ZoneType[client]] + 1;

		if(gI_ZoneType[client] == Zone_Stage)
		{
			gI_ZoneData[client][gI_ZoneType[client]] = gI_Stages + 1;
		}
	}
	gB_ZoneDataInput[client] = false;
	gB_CommandToEdit[client] = false;

	FormatEx(sMenuItem, 64, "%T", "ZoneSetData", client, gI_ZoneData[client][gI_ZoneType[client]]);
	menu.AddItem("datafromchat", sMenuItem);

	menu.Display(client, 600);
}

void CreateAdjustMenu(int client, int page)
{
	Menu hMenu = new Menu(ZoneAdjuster_Handler);
	char sMenuItem[64];
	hMenu.SetTitle("%T", "ZoneAdjustPosition", client);

	FormatEx(sMenuItem, 64, "%T", "ZoneAdjustDone", client);
	hMenu.AddItem("done", sMenuItem);
	FormatEx(sMenuItem, 64, "%T", "ZoneAdjustCancel", client);
	hMenu.AddItem("cancel", sMenuItem);

	char sAxis[4];
	strcopy(sAxis, 4, "XYZ");

	char sDisplay[32];
	char sInfo[16];

	for(int iPoint = 1; iPoint <= 2; iPoint++)
	{
		for(int iAxis = 0; iAxis < 3; iAxis++)
		{
			for(int iState = 1; iState <= 2; iState++)
			{
				FormatEx(sDisplay, 32, "%T %c%.01f", "ZonePoint", client, iPoint, sAxis[iAxis], (iState == 1)? '+':'-', gF_Modifier[client]);
				FormatEx(sInfo, 16, "%d;%d;%d", iPoint, iAxis, iState);
				hMenu.AddItem(sInfo, sDisplay);
			}
		}
	}

	hMenu.ExitButton = false;
	hMenu.DisplayAt(client, page, MENU_TIME_FOREVER);
}

public int ZoneAdjuster_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		char sInfo[16];
		menu.GetItem(param2, sInfo, 16);

		if(StrEqual(sInfo, "done"))
		{
			CreateEditMenu(param1);
		}

		else if(StrEqual(sInfo, "cancel"))
		{
			if (gI_ZoneID[param1] != -1)
			{
				// reenable original zone
				gA_ZoneCache[gI_ZoneID[param1]].bZoneInitialized = true;
			}

			Reset(param1);
		}

		else
		{
			char sAxis[4];
			strcopy(sAxis, 4, "XYZ");

			char sExploded[3][8];
			ExplodeString(sInfo, ";", sExploded, 3, 8);

			int iPoint = StringToInt(sExploded[0]);
			int iAxis = StringToInt(sExploded[1]);
			bool bIncrease = view_as<bool>(StringToInt(sExploded[2]) == 1);

			((iPoint == 1)? gV_Point1:gV_Point2)[param1][iAxis] += ((bIncrease)? gF_Modifier[param1]:-gF_Modifier[param1]);
			Shavit_PrintToChat(param1, "%T", (bIncrease)? "ZoneSizeIncrease":"ZoneSizeDecrease", param1, gS_ChatStrings.sVariable2, sAxis[iAxis], gS_ChatStrings.sText, iPoint, gS_ChatStrings.sVariable, gF_Modifier[param1], gS_ChatStrings.sText);

			CreateAdjustMenu(param1, GetMenuSelectionPosition());
		}
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

void InsertZone(int client)
{
	int iType = gI_ZoneType[client];
	int iIndex = GetZoneIndex(iType, gI_ZoneTrack[client]);
	bool bInsert = (gI_ZoneDatabaseID[client] == -1 && (iIndex == -1 || iType >= Zone_Start));

	char sQuery[512];

	if(bInsert) // insert
	{
		Shavit_LogMessage("%L - added %s to map `%s`.", client, gS_ZoneNames[iType], gS_Map);

		FormatEx(sQuery, 512,
			"INSERT INTO %smapzones (map, type, corner1_x, corner1_y, corner1_z, corner2_x, corner2_y, corner2_z, destination_x, destination_y, destination_z, track, flags, data, hookname) VALUES ('%s', %d, '%.03f', '%.03f', '%.03f', '%.03f', '%.03f', '%.03f', '%.03f', '%.03f', '%.03f', %d, %d, %d, '%s');",
			gS_MySQLPrefix, gS_Map, iType, gV_Point1[client][0], gV_Point1[client][1], gV_Point1[client][2], gV_Point2[client][0], gV_Point2[client][1], gV_Point2[client][2], gV_Teleport[client][0], gV_Teleport[client][1], gV_Teleport[client][2], gI_ZoneTrack[client], gI_ZoneFlags[client], gI_ZoneData[client][iType], gS_ZoneHookname[client]);
	}

	else // update
	{
		Shavit_LogMessage("%L - updated %s in map `%s`.", client, gS_ZoneNames[iType], gS_Map);

		if(gI_ZoneDatabaseID[client] == -1)
		{
			for(int i = 0; i < gI_MapZones; i++)
			{
				if(gA_ZoneCache[i].bZoneInitialized && gA_ZoneCache[i].iZoneType == iType && gA_ZoneCache[i].iZoneTrack == gI_ZoneTrack[client])
				{
					gI_ZoneDatabaseID[client] = gA_ZoneCache[i].iDatabaseID;
				}
			}
		}

		FormatEx(sQuery, 512,
			"UPDATE %smapzones SET corner1_x = '%.03f', corner1_y = '%.03f', corner1_z = '%.03f', corner2_x = '%.03f', corner2_y = '%.03f', corner2_z = '%.03f', destination_x = '%.03f', destination_y = '%.03f', destination_z = '%.03f', track = %d, flags = %d, data = %d WHERE %s = %d;",
			gS_MySQLPrefix, gV_Point1[client][0], gV_Point1[client][1], gV_Point1[client][2], gV_Point2[client][0], gV_Point2[client][1], gV_Point2[client][2], gV_Teleport[client][0], gV_Teleport[client][1], gV_Teleport[client][2], gI_ZoneTrack[client], gI_ZoneFlags[client], gI_ZoneData[client][iType], (gB_MySQL)? "id":"rowid", gI_ZoneDatabaseID[client]);
	}

	gH_SQL.Query(SQL_InsertZone_Callback, sQuery, GetClientSerial(client));
}

public void SQL_InsertZone_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (zone insert) SQL query failed. Reason: %s", error);

		return;
	}

	int client = GetClientFromSerial(data);

	if(client == 0)
	{
		return;
	}

	UnloadZones(0);
	RefreshZones();
	LoadStageZones();
	LoadCheckpointZones();
	Reset(client);
}

public Action Timer_DrawEverything(Handle Timer)
{
	if(gI_MapZones == 0)
	{
		return Plugin_Continue;
	}

	static int iCycle = 0;

	if(iCycle >= gI_MapZones)
	{
		iCycle = 0;
	}

	for(int i = iCycle; i < gI_MapZones; i++, iCycle++)
	{
		if(gA_ZoneCache[i].bZoneInitialized)
		{
			int type = gA_ZoneCache[i].iZoneType;
			int track = gA_ZoneCache[i].iZoneTrack;

			if(gA_ZoneSettings[type][track].bVisible || (gA_ZoneCache[i].iZoneFlags & ZF_ForceRender) > 0)
			{
				DrawZone(gV_MapZones_Visual[i],
						GetZoneColors(type, track),
						gCV_Interval.FloatValue,
						gA_ZoneSettings[type][track].fWidth,
						gA_ZoneSettings[type][track].bFlatZone,
						gA_ZoneSettings[type][track].iBeam,
						gA_ZoneSettings[type][track].iHalo);
			}
		}
	}

	iCycle = 0;

	return Plugin_Continue;
}

int[] GetZoneColors(int type, int track, int customalpha = 0)
{
	int colors[4];
	colors[0] = gA_ZoneSettings[type][track].iRed;
	colors[1] = gA_ZoneSettings[type][track].iGreen;
	colors[2] = gA_ZoneSettings[type][track].iBlue;
	colors[3] = (customalpha > 0)? customalpha:gA_ZoneSettings[type][track].iAlpha;

	return colors;
}

public Action Timer_Draw(Handle Timer, any data)
{
	int client = GetClientFromSerial(data);

	if(client == 0 || gI_MapStep[client] == 0)
	{
		Reset(client);

		return Plugin_Stop;
	}

	float vPlayerOrigin[3];
	GetClientAbsOrigin(client, vPlayerOrigin);

	float origin[3];

	if(gB_CursorTracing[client])
	{
		origin = GetAimPosition(client);
	}

	else if(!(gB_SnapToWall[client] && SnapToWall(vPlayerOrigin, client, origin)))
	{
		origin = SnapToGrid(vPlayerOrigin, gI_GridSnap[client], false);
	}

	else
	{
		gV_WallSnap[client] = origin;
	}

	if(gI_MapStep[client] == 1 || gV_Point2[client][0] == 0.0)
	{
		origin[2] = (vPlayerOrigin[2] + gCV_Height.FloatValue);
	}

	else
	{
		origin = gV_Point2[client];
	}

	int type = gI_ZoneType[client];
	int track = gI_ZoneTrack[client];

	if(!EmptyVector(gV_Point1[client]) || !EmptyVector(gV_Point2[client]))
	{
		float points[8][3];
		points[0] = gV_Point1[client];
		points[7] = origin;
		CreateZonePoints(points, gCV_Offset.FloatValue);

		// This is here to make the zone setup grid snapping be 1:1 to how it looks when done with the setup.
		origin = points[7];

		DrawZone(points, GetZoneColors(type, track, 125), 0.1, gA_ZoneSettings[type][track].fWidth, false, gI_BeamSpriteIgnoreZ, gA_ZoneSettings[type][track].iHalo);

		if(gI_ZoneType[client] == Zone_Teleport && !EmptyVector(gV_Teleport[client]))
		{
			TE_SetupEnergySplash(gV_Teleport[client], NULL_VECTOR, false);
			TE_SendToAll(0.0);
		}
	}

	if(gI_MapStep[client] != 3 && !EmptyVector(origin))
	{
		origin[2] -= gCV_Height.FloatValue;

		TE_SetupBeamPoints(vPlayerOrigin, origin, gI_BeamSpriteIgnoreZ, gA_ZoneSettings[type][track].iHalo, 0, 0, 0.1, 1.0, 1.0, 0, 0.0, {255, 255, 255, 75}, 0);
		TE_SendToAll(0.0);

		// visualize grid snap
		float snap1[3];
		float snap2[3];

		for(int i = 0; i < 3; i++)
		{
			snap1 = origin;
			snap1[i] -= (gI_GridSnap[client] / 2);

			snap2 = origin;
			snap2[i] += (gI_GridSnap[client] / 2);

			TE_SetupBeamPoints(snap1, snap2, gI_BeamSpriteIgnoreZ, gA_ZoneSettings[type][track].iHalo, 0, 0, 0.1, 1.0, 1.0, 0, 0.0, {255, 255, 255, 75}, 0);
			TE_SendToAll(0.0);
		}
	}

	return Plugin_Continue;
}

void DrawZone(float points[8][3], int color[4], float life, float width, bool flat, int beam, int halo)
{
	static int pairs[][] =
	{
		{ 0, 2 },
		{ 2, 6 },
		{ 6, 4 },
		{ 4, 0 },
		{ 0, 1 },
		{ 3, 1 },
		{ 3, 2 },
		{ 3, 7 },
		{ 5, 1 },
		{ 5, 4 },
		{ 6, 7 },
		{ 7, 5 }
	};

	for(int i = 0; i < ((flat)? 4:12); i++)
	{
		TE_SetupBeamPoints(points[pairs[i][0]], points[pairs[i][1]], beam, halo, 0, 0, life, width, width, 0, 0.0, color, 0);
		TE_SendToAll(0.0);
	}
}

// original by blacky
// creates 3d box from 2 points
void CreateZonePoints(float point[8][3], float offset = 0.0)
{
	// calculate all zone edges
	for(int i = 1; i < 7; i++)
	{
		for(int j = 0; j < 3; j++)
		{
			point[i][j] = point[((i >> (2 - j)) & 1) * 7][j];
		}
	}

	// apply beam offset
	if(offset != 0.0)
	{
		float center[2];
		center[0] = ((point[0][0] + point[7][0]) / 2);
		center[1] = ((point[0][1] + point[7][1]) / 2);

		for(int i = 0; i < 8; i++)
		{
			for(int j = 0; j < 2; j++)
			{
				if(point[i][j] < center[j])
				{
					point[i][j] += offset;
				}

				else if(point[i][j] > center[j])
				{
					point[i][j] -= offset;
				}
			}
		}
	}
}

void SQL_DBConnect()
{
	GetTimerSQLPrefix(gS_MySQLPrefix, 32);
	gH_SQL = GetTimerDatabaseHandle();
	gB_MySQL = IsMySQLDatabase(gH_SQL);

	char sQuery[1024];
	FormatEx(sQuery, 1024,
		"CREATE TABLE IF NOT EXISTS `%smapzones` (`id` INT AUTO_INCREMENT, `map` VARCHAR(128), `type` INT, `corner1_x` FLOAT, `corner1_y` FLOAT, `corner1_z` FLOAT, `corner2_x` FLOAT, `corner2_y` FLOAT, `corner2_z` FLOAT, `destination_x` FLOAT NOT NULL DEFAULT 0, `destination_y` FLOAT NOT NULL DEFAULT 0, `destination_z` FLOAT NOT NULL DEFAULT 0, `track` INT NOT NULL DEFAULT 0, `flags` INT NOT NULL DEFAULT 0, `data` INT NOT NULL DEFAULT 0, `hookname` VARCHAR(128) NOT NULL DEFAULT 'NONE', PRIMARY KEY (`id`))%s;",
		gS_MySQLPrefix, (gB_MySQL)? " ENGINE=INNODB":"");

	gH_SQL.Query(SQL_CreateTable_Callback, sQuery);
}

public void SQL_CreateTable_Callback(Database db, DBResultSet results, const char[] error, any data)
{
	if(results == null)
	{
		LogError("Timer (zones module) error! Map zones' table creation failed. Reason: %s", error);

		return;
	}

	gB_Connected = true;
	
	OnMapStart();
}

public void Shavit_OnRestart(int client, int track)
{
	if(gCV_TeleportToStart.BoolValue)
	{
		int iIndex = -1;

		// standard zoning
		if((iIndex = GetZoneIndex(Zone_Start, track)) != -1)
		{
			float fCenter[3];
			iIndex = GetZoneIndex(Zone_Start, track);
			fCenter[0] = gV_ZoneCenter[iIndex][0];
			fCenter[1] = gV_ZoneCenter[iIndex][1];
			fCenter[2] = gV_MapZones[iIndex][0][2] + 2.0;

			TeleportEntity(client, fCenter, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		}

		Shavit_StartTimer(client, track);
	}
}

public void Shavit_OnEnd(int client, int track)
{
	if(gCV_TeleportToEnd.BoolValue)
	{
		int iIndex = -1;

		if((iIndex = GetZoneIndex(Zone_End, track)) != -1)
		{
			float fCenter[3];
			iIndex = GetZoneIndex(Zone_End, track);
			fCenter[0] = gV_ZoneCenter[iIndex][0];
			fCenter[1] = gV_ZoneCenter[iIndex][1];
			fCenter[2] = gV_MapZones[iIndex][0][2];

			TeleportEntity(client, fCenter, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		}
	}
}

bool EmptyVector(float vec[3])
{
	return (IsNullVector(vec) || (vec[0] == 0.0 && vec[1] == 0.0 && vec[2] == 0.0));
}

// returns -1 if there's no zone
int GetZoneIndex(int type, int track, int start = 0)
{
	if(gI_MapZones == 0)
	{
		return -1;
	}

	for(int i = start; i < gI_MapZones; i++)
	{
		if(gA_ZoneCache[i].bZoneInitialized && gA_ZoneCache[i].iZoneType == type && (gA_ZoneCache[i].iZoneTrack == track || track == -1))
		{
			return i;
		}
	}

	return -1;
}

public void Player_Spawn(Event event, const char[] name, bool dontBroadcast)
{
	Reset(GetClientOfUserId(event.GetInt("userid")));
}

public void Round_Start(Event event, const char[] name, bool dontBroadcast)
{
	gB_ZonesCreated = false;

	RequestFrame(Frame_CreateZoneEntities);
}

public void Frame_CreateZoneEntities(any data)
{
	CreateZoneEntities();
}

float Abs(float input)
{
	if(input < 0.0)
	{
		return -input;
	}

	return input;
}

void CreateZoneEntities()
{
	if(gB_ZonesCreated)
	{
		return;
	}

	delete gA_HookTriggers;
	gA_HookTriggers = new ArrayList();

	for(int i = 0; i < gI_MapZones; i++)
	{
		for(int j = 1; j <= MaxClients; j++)
		{
			for(int k = 0; k < TRACKS_SIZE; k++)
			{
				gB_InsideZone[j][gA_ZoneCache[i].iZoneType][k] = false;
			}

			gB_InsideZoneID[j][i] = false;
		}

		if(gA_ZoneCache[i].iEntityID != -1)
		{
			KillZoneEntity(i);

			gA_ZoneCache[i].iEntityID = -1;
		}

		if(!gA_ZoneCache[i].bZoneInitialized)
		{
			continue;
		}

		if(StrEqual(gA_ZoneCache[i].sZoneHookname, "NONE"))//create non-hooked zones
		{
			int entity = CreateEntityByName("trigger_multiple");

			if(entity == -1)
			{
				LogError("\"trigger_multiple\" creation failed, map %s.", gS_Map);

				continue;
			}

			DispatchKeyValue(entity, "wait", "0");
			DispatchKeyValue(entity, "spawnflags", "4097");
			
			if(!DispatchSpawn(entity))
			{
				LogError("\"trigger_multiple\" spawning failed, map %s.", gS_Map);

				continue;
			}

			ActivateEntity(entity);
			SetEntityModel(entity, "models/props/cs_office/vending_machine.mdl");
			SetEntProp(entity, Prop_Send, "m_fEffects", 32);

			TeleportEntity(entity, gV_ZoneCenter[i], NULL_VECTOR, NULL_VECTOR);

			float distance_x = Abs(gV_MapZones[i][0][0] - gV_MapZones[i][1][0]) / 2;
			float distance_y = Abs(gV_MapZones[i][0][1] - gV_MapZones[i][1][1]) / 2;
			float distance_z = Abs(gV_MapZones[i][0][2] - gV_MapZones[i][1][2]) / 2;

			float height = ((IsSource2013(gEV_Type))? 62.0:72.0) / 2;

			float min[3];
			min[0] = -distance_x + gCV_BoxOffset.FloatValue;
			min[1] = -distance_y + gCV_BoxOffset.FloatValue;
			min[2] = -distance_z + height;
			SetEntPropVector(entity, Prop_Send, "m_vecMins", min);

			float max[3];
			max[0] = distance_x - gCV_BoxOffset.FloatValue;
			max[1] = distance_y - gCV_BoxOffset.FloatValue;
			max[2] = distance_z - height;
			SetEntPropVector(entity, Prop_Send, "m_vecMaxs", max);

			SetEntProp(entity, Prop_Send, "m_nSolidType", 2);

			SDKHook(entity, SDKHook_StartTouchPost, StartTouchPost);
			SDKHook(entity, SDKHook_StartTouchPost, StartTouchPost_Bot);
			SDKHook(entity, SDKHook_EndTouchPost, EndTouchPost);
			SDKHook(entity, SDKHook_TouchPost, TouchPost);

			gI_EntityZone[entity] = i;
			gA_ZoneCache[i].iEntityID = entity;

			char sTargetname[32];
			FormatEx(sTargetname, 32, "shavit_zones_%d_%d", gA_ZoneCache[i].iZoneTrack, gA_ZoneCache[i].iZoneType);
			DispatchKeyValue(entity, "targetname", sTargetname);
		}

		else//create hookzones
		{
			for(int index = 0; index < gA_Triggers.Length; index++)
			{
				int iEnt = gA_Triggers.Get(index);
				char sTriggerName[128];
				GetEntPropString(iEnt, Prop_Send, "m_iName", sTriggerName, 128, 0);

				if(StrEqual(gA_ZoneCache[i].sZoneHookname, sTriggerName))
				{
					if(gA_ZoneCache[i].iZoneType != Zone_Mark)
					{
						for(int j = 0; j < 8; j++)
						{
							for(int k = 0; k < 3; k++)
							{
								gV_MapZones_Visual[i][j][k] = 0.0;//do not set their visual point, use trigger material instead
							}
						}

						gA_HookTriggers.Push(iEnt);//do not push markzone index to arraylist
					}

					SDKHook(iEnt, SDKHook_StartTouchPost, StartTouchPost);
					SDKHook(iEnt, SDKHook_StartTouchPost, StartTouchPost_Bot);
					SDKHook(iEnt, SDKHook_EndTouchPost, EndTouchPost);
					SDKHook(iEnt, SDKHook_TouchPost, TouchPost);

					gI_EntityZone[iEnt] = i;
					gA_ZoneCache[i].iEntityID = iEnt;

					break;// stop looping from finding triggers to hook
				}
			}
		}

		gB_ZonesCreated = true;
	}
}

public void StartTouchPost(int entity, int other)
{
	if(other < 1 || other > MaxClients || gI_EntityZone[entity] == -1 || !gA_ZoneCache[gI_EntityZone[entity]].bZoneInitialized ||
		(gCV_EnforceTracks.BoolValue && gA_ZoneCache[gI_EntityZone[entity]].iZoneType > Zone_End && gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack != Shavit_GetClientTrack(other)))
	{
		return;
	}

	if(!IsFakeClient(other))
	{
		TimerStatus status = Shavit_GetTimerStatus(other);

		int type = gA_ZoneCache[gI_EntityZone[entity]].iZoneType;

		if(type == Zone_Start)
		{
			gI_ClientCurrentStage[other] = 1;
			gI_LastStage[other] = 1;
			gI_ClientCurrentCP[other] = 0;
			gI_LastCheckpoint[other] = (gB_LinearMap) ? 0 : 1;
			gI_InsideZoneIndex[other] = gI_EntityZone[entity];
		}

		else if(type == Zone_End)
		{
			if(gI_Stages > 1)//prevent no stages.
			{
				gI_ClientCurrentStage[other] = gI_Stages + 1;//a hack that record the last stage's time

				if(gI_ClientCurrentStage[other] > gI_LastStage[other] && gI_ClientCurrentStage[other] - gI_LastStage[other] == 1 && !gB_LinearMap)
				{
					gB_IntoStage[other] = true;
					Shavit_FinishStage(other);
				}

				gI_LastStage[other] = gI_Stages + 1;
			}

			gI_ClientCurrentCP[other] = (gB_LinearMap) ? gI_Checkpoints + 1 : gI_Stages + 1;

			if(gI_ClientCurrentCP[other] > gI_LastCheckpoint[other] && gI_ClientCurrentCP[other] - gI_LastCheckpoint[other] == 1 && !gB_SingleStageTiming[other])
			{
				gB_IntoCheckpoint[other] = true;
				Shavit_FinishCheckpoint(other);
			}

			gI_LastCheckpoint[other] = (gB_LinearMap) ? gI_Checkpoints + 1 : gI_Stages + 1;
			
			if(status != Timer_Stopped && !Shavit_IsPaused(other) && !gB_SingleStageTiming[other] && Shavit_GetClientTrack(other) == gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack)
			{
				Shavit_FinishMap(other, gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack);
			}
		}

		else if(type == Zone_Stage)
		{
			gI_InsideZoneIndex[other] = gI_EntityZone[entity];
			gI_ClientCurrentStage[other] = gA_ZoneCache[gI_EntityZone[entity]].iZoneData;
			gI_ClientCurrentCP[other] = gA_ZoneCache[gI_EntityZone[entity]].iZoneData;

			if(gI_ClientCurrentStage[other] > gI_LastStage[other] && gI_ClientCurrentStage[other] - gI_LastStage[other] == 1)
			{
				gB_IntoStage[other] = true;
				Shavit_FinishStage(other);
			}

			if(gI_ClientCurrentCP[other] > gI_LastCheckpoint[other] && gI_ClientCurrentCP[other] - gI_LastCheckpoint[other] == 1 && !gB_SingleStageTiming[other])
			{
				gB_IntoCheckpoint[other] = true;
				Shavit_FinishCheckpoint(other);
			}

			gI_LastStage[other] = gA_ZoneCache[gI_EntityZone[entity]].iZoneData;
			gI_LastCheckpoint[other] = gA_ZoneCache[gI_EntityZone[entity]].iZoneData;
		}

		else if(type == Zone_Checkpoint)
		{
			gI_ClientCurrentCP[other] = gA_ZoneCache[gI_EntityZone[entity]].iZoneData;

			if(gI_ClientCurrentCP[other] > gI_LastCheckpoint[other] && gI_ClientCurrentCP[other] - gI_LastCheckpoint[other] == 1)
			{
				gB_IntoCheckpoint[other] = true;
				Shavit_FinishCheckpoint(other);
			}

			gI_LastCheckpoint[other] = gA_ZoneCache[gI_EntityZone[entity]].iZoneData;
		}

		else if(type == Zone_Stop)
		{
			if(status != Timer_Stopped)
			{
				Shavit_StopTimer(other);
				Shavit_PrintToChat(other, "%T", "ZoneStopEnter", other, gS_ChatStrings.sWarning, gS_ChatStrings.sVariable2, gS_ChatStrings.sWarning);
			}
		}

		else if(type == Zone_Teleport)
		{
			TeleportEntity(other, gV_Destinations[gI_EntityZone[entity]], NULL_VECTOR, NULL_VECTOR);
		}

		else if(type == Zone_Mark)
		{
			return;//cant do anything in mark zone, insidezone or else are not permitted.
		}

		gB_InsideZone[other][gA_ZoneCache[gI_EntityZone[entity]].iZoneType][gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack] = true;
		gB_InsideZoneID[other][gI_EntityZone[entity]] = true;

		Call_StartForward(gH_Forwards_EnterZone);
		Call_PushCell(other);
		Call_PushCell(gA_ZoneCache[gI_EntityZone[entity]].iZoneType);
		Call_PushCell(gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack);
		Call_PushCell(gI_EntityZone[entity]);
		Call_PushCell(entity);
		Call_PushCell(gA_ZoneCache[gI_EntityZone[entity]].iZoneData);
		Call_Finish();
	}
}

public void StartTouchPost_Bot(int entity, int other)
{
	if(IsFakeClient(other))
	{
		if(gA_ZoneCache[gI_EntityZone[entity]].iZoneType == Zone_Start)
		{
			gI_ClientCurrentCP[other] = 0;
		}
		else if(gA_ZoneCache[gI_EntityZone[entity]].iZoneType == Zone_Checkpoint)
		{
			gI_ClientCurrentCP[other] = gA_ZoneCache[gI_EntityZone[entity]].iZoneData;
		}
	}
}

public void EndTouchPost(int entity, int other)
{
	if(other < 1 || other > MaxClients || gI_EntityZone[entity] == -1 || gI_EntityZone[entity] >= sizeof(gA_ZoneCache) || IsFakeClient(other))
	{
		return;
	}

	int entityzone = gI_EntityZone[entity];
	int type = gA_ZoneCache[entityzone].iZoneType;
	int track = gA_ZoneCache[entityzone].iZoneTrack;

	gB_InsideZone[other][type][track] = false;
	gB_InsideZoneID[other][entityzone] = false;

	Call_StartForward(gH_Forwards_LeaveZone);
	Call_PushCell(other);
	Call_PushCell(type);
	Call_PushCell(track);
	Call_PushCell(entityzone);
	Call_PushCell(entity);
	Call_PushCell(gA_ZoneCache[entityzone].iZoneData);
	Call_Finish();
}

public void TouchPost(int entity, int other)
{
	if(other < 1 || other > MaxClients || gI_EntityZone[entity] == -1 || IsFakeClient(other) ||
		(gCV_EnforceTracks.BoolValue && gA_ZoneCache[gI_EntityZone[entity]].iZoneType > Zone_End && gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack != Shavit_GetClientTrack(other)))
	{
		return;
	}

	// do precise stuff here, this will be called *A LOT*
	int type = gA_ZoneCache[gI_EntityZone[entity]].iZoneType;

	if(type == Zone_Start)
	{
		// start timer instantly for main track, but require bonuses to have the current timer stopped
		// so you don't accidentally step on those while running
		if(Shavit_GetTimerStatus(other) == Timer_Stopped || Shavit_GetClientTrack(other) != Track_Main)
		{
			gB_SingleStageTiming[other] = false;
			Shavit_StartTimer(other, gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack);
		}

		else if(gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack == Track_Main)
		{
			gB_SingleStageTiming[other] = false;
			Shavit_StartTimer(other, Track_Main);
		}
	}

	else if(type == Zone_End)
	{
		Action result = Plugin_Continue;
		Call_StartForward(gH_Forwards_OnEndZone);
		Call_PushCell(other);
		Call_Finish(result);

		if(result != Plugin_Continue)
		{
			return;
		}
	}

	else if(type == Zone_Stage)
	{
		if(Shavit_GetClientTrack(other) == Track_Main)
		{
			Action result = Plugin_Continue;
			Call_StartForward(gH_Forwards_OnStage);
			Call_PushCell(other);
			Call_PushCell(gA_ZoneCache[gI_EntityZone[entity]].iZoneData);
			Call_Finish(result);

			if(result != Plugin_Continue)
			{
				return;
			}

			if(gB_SingleStageTiming[other])
			{
				Shavit_StartTimer(other, Track_Main);
			}
		}
	}

	else if(type == Zone_Stop)
	{
		if(Shavit_GetTimerStatus(other) != Timer_Stopped)
		{
			Shavit_StopTimer(other);
			Shavit_PrintToChat(other, "%T", "ZoneStopEnter", other, gS_ChatStrings.sWarning, gS_ChatStrings.sVariable2, gS_ChatStrings.sWarning);
		}
	}

	else if(type == Zone_Teleport)
	{
		TeleportEntity(other, gV_Destinations[gI_EntityZone[entity]], NULL_VECTOR, NULL_VECTOR);
	}

	gB_InsideZone[other][gA_ZoneCache[gI_EntityZone[entity]].iZoneType][gA_ZoneCache[gI_EntityZone[entity]].iZoneTrack] = true;
	gB_InsideZoneID[other][gI_EntityZone[entity]] = true;
}

// Reference: https://forums.alliedmods.net/showpost.php?p=2007420&postcount=1
bool IsEntityInsideZone(int entity, float point[8][3])
{
    float entityPos[3];
    
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", entityPos);
    entityPos[2] += 5.0;
    
    for(int i = 0; i < 3; i++)
    {
        if((point[0][i] >= entityPos[i]) == (point[7][i] >= entityPos[i]))
        {
            return false;
        }
    }

    return true;
}

void transmitTriggers(int client, bool btransmit)
{
	if(!IsValidClient(client))
	{
		return;
	}

	static bool bHooked = false;
	
	if(bHooked == btransmit)
	{
		return;
	}

	for(int i = 0; i < gA_HookTriggers.Length; i++)
	{
		int entity = gA_HookTriggers.Get(i);
		int effectFlags = GetEntData(entity, gI_Offset_m_fEffects);
		int edictFlags = GetEdictFlags(entity);
		
		if(btransmit)
		{
			effectFlags &= ~EF_NODRAW;
			edictFlags &= ~FL_EDICT_DONTSEND;
		}

		else
		{
			effectFlags |= EF_NODRAW;
			edictFlags |= FL_EDICT_DONTSEND;
		}
		
		SetEntData(entity, gI_Offset_m_fEffects, effectFlags);
		ChangeEdictState(entity, gI_Offset_m_fEffects);
		SetEdictFlags(entity, edictFlags);

		static Handle gH_DrawZonesToClient = null;
		
		if(btransmit)
		{
			SDKHook(entity, SDKHook_SetTransmit, Hook_SetTransmit);
			if(gH_DrawZonesToClient == null)
			{
				gH_DrawZonesToClient = CreateTimer(gCV_Interval.FloatValue, Timer_DrawZonesToClient, GetClientSerial(client), TIMER_REPEAT);
			}
		}

		else
		{
			SDKUnhook(entity, SDKHook_SetTransmit, Hook_SetTransmit);
			delete gH_DrawZonesToClient;
		}
	}

	bHooked = btransmit;
}

public Action Hook_SetTransmit(int entity, int other)
{
	if(!gB_ShowTriggers[other])
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public Action Timer_DrawZonesToClient(Handle Timer, any data)
{
	if(gI_MapZones == 0)
	{
		return Plugin_Continue;
	}

	int client = GetClientFromSerial(data);

	static int iCycle = 0;

	if(iCycle >= gI_MapZones)
	{
		iCycle = 0;
	}

	for(int i = iCycle; i < gI_MapZones; i++, iCycle++)
	{
		if(gA_ZoneCache[i].bZoneInitialized)
		{
			int type = gA_ZoneCache[i].iZoneType;
			int track = gA_ZoneCache[i].iZoneTrack;

			if(gA_ZoneSettings[type][track].bVisible || (gA_ZoneCache[i].iZoneFlags & ZF_ForceRender) > 0)
			{
				continue;//already draw to everyone, find next undrawn
			}

			DrawZoneToSingleClient(client, 
								gV_MapZones_Visual[i], 
								GetZoneColors(type, track), 
								gCV_Interval.FloatValue, 
								gA_ZoneSettings[type][track].fWidth, 
								gA_ZoneSettings[type][track].bFlatZone, 
								gA_ZoneSettings[type][track].iBeam, 
								gA_ZoneSettings[type][track].iHalo);
		}
	}

	iCycle = 0;

	return Plugin_Continue;
}

void DrawZoneToSingleClient(int client, float points[8][3], int color[4], float life, float width, bool flat, int beam, int halo)
{
	static int pairs[][] =
	{
		{ 0, 2 },
		{ 2, 6 },
		{ 6, 4 },
		{ 4, 0 },
		{ 0, 1 },
		{ 3, 1 },
		{ 3, 2 },
		{ 3, 7 },
		{ 5, 1 },
		{ 5, 4 },
		{ 6, 7 },
		{ 7, 5 }
	};

	for(int i = 0; i < ((flat)? 4:12); i++)
	{
		TE_SetupBeamPoints(points[pairs[i][0]], points[pairs[i][1]], beam, halo, 0, 0, life, width, width, 0, 0.0, color, 0);
		TE_SendToClient(client, 0.0);
	}
}
