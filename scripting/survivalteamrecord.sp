#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_gamerules>

// ================================================================
// Info
// ================================================================

public Plugin myinfo = {
    name        = "[L4D2] Survival Team Record Persist",
    author      = "Ren",
    description = "Persist Survival HUD 'Team Record'",
    version     = "1.0.0",
    url         = "N/A"
};

// ================================================================
// Constants
// ================================================================

#define CHAT_PREFIX "[STR]"

#define KV_ROOT_NAME "L4D2_SurvivalTeamRecord"
#define KV_SECTION_RECORDS "records"
#define KV_KEY_GLOBAL "__GLOBAL__"

#define DATA_FILE_RELATIVE_PATH "data/l4d2_survival_teamrecord.kv"

#define GR_PROP_TEAM_BEST_ROUND_TIME "m_flTeamBestRoundTime"

// ================================================================
// Globals
// ================================================================

ConVar g_cvEnable;
ConVar g_cvPerMap;
ConVar g_cvCaptureTries;
ConVar g_cvCaptureStep;
ConVar g_cvDebug;

ConVar g_cvGameMode;

char g_szCurrentMap[64];
char g_szDataFilePath[PLATFORM_MAX_PATH];

float g_flStoredRecord = 0.0;

Handle g_hCaptureTimer = null;
int   g_nCaptureSamplesLeft = 0;
float g_flCaptureBest = 0.0;

// ================================================================
// Leaf-level helpers
// ================================================================

static float ClampFloat(float flValue, float flMinimum, float flMaximum) {
    if (flValue < flMinimum) {
        return flMinimum;
    }

    if (flValue > flMaximum) {
        return flMaximum;
    }

    return flValue;
}

static void DebugLog(const char[] szFormat, any ...) {
    if ((g_cvDebug == null) || (g_cvDebug.IntValue <= 0)) {
        return;
    }

    char szBuffer[256];
    VFormat(szBuffer, sizeof(szBuffer), szFormat, 2);
    LogMessage("%s %s", CHAT_PREFIX, szBuffer);
}

static bool IsSurvivalMode() {
    if (g_cvGameMode == null) {
        return false;
    }

    char szMode[64];
    g_cvGameMode.GetString(szMode, sizeof(szMode));

    return StrEqual(szMode, "survival", false);
}

static void BuildPaths() {
    GetCurrentMap(g_szCurrentMap, sizeof(g_szCurrentMap));
    BuildPath(Path_SM, g_szDataFilePath, sizeof(g_szDataFilePath), DATA_FILE_RELATIVE_PATH);
}

static void GetScopeKey(char szKey[64]) {
    if ((g_cvPerMap == null) || (g_cvPerMap.IntValue <= 0)) {
        strcopy(szKey, 64, KV_KEY_GLOBAL);
        return;
    }

    strcopy(szKey, 64, g_szCurrentMap);
}

static float LoadRecordFromFile() {
    float flRecord = 0.0;

    KeyValues kvRoot = new KeyValues(KV_ROOT_NAME);

    if (kvRoot.ImportFromFile(g_szDataFilePath)) {
        char szKey[64];
        GetScopeKey(szKey);

        if (kvRoot.JumpToKey(KV_SECTION_RECORDS, false)) {
            flRecord = kvRoot.GetFloat(szKey, 0.0);
            kvRoot.GoBack();
        }
    }

    delete kvRoot;

    if (flRecord < 0.0) {
        flRecord = 0.0;
    }

    return flRecord;
}

static void SaveRecordToFile(float flRecord) {
    if (flRecord < 0.0) {
        flRecord = 0.0;
    }

    KeyValues kvRoot = new KeyValues(KV_ROOT_NAME);

    kvRoot.ImportFromFile(g_szDataFilePath);

    kvRoot.JumpToKey(KV_SECTION_RECORDS, true);

    char szKey[64];
    GetScopeKey(szKey);

    kvRoot.SetFloat(szKey, flRecord);

    kvRoot.Rewind();
    kvRoot.ExportToFile(g_szDataFilePath);

    delete kvRoot;
}

static float GR_GetFloat(const char[] szPropName) {
    return GameRules_GetPropFloat(szPropName, 0);
}

static void GR_SetFloatForce(const char[] szPropName, float flValue) {
    GameRules_SetPropFloat(szPropName, flValue, 0, true);
}

// ================================================================
// Mid-level logic
// ================================================================

static void ApplyStoredRecordNow() {
    if ((g_cvEnable == null) || (g_cvEnable.IntValue <= 0)) {
        return;
    }

    if (!IsSurvivalMode()) {
        return;
    }

    if (g_flStoredRecord < 0.0) {
        g_flStoredRecord = 0.0;
    }

    GR_SetFloatForce(GR_PROP_TEAM_BEST_ROUND_TIME, g_flStoredRecord);

    if ((g_cvDebug != null) && (g_cvDebug.IntValue > 0)) {
        float flReadback = GR_GetFloat(GR_PROP_TEAM_BEST_ROUND_TIME);
        DebugLog("Apply: stored=%.3f readback=%.3f", g_flStoredRecord, flReadback);
    }
}

static void StopCaptureTimer() {
    if (g_hCaptureTimer == null) {
        return;
    }

    KillTimer(g_hCaptureTimer);
    g_hCaptureTimer = null;
}

static void StartCaptureAfterRoundEnd() {
    if ((g_cvEnable == null) || (g_cvEnable.IntValue <= 0)) {
        return;
    }

    if (!IsSurvivalMode()) {
        return;
    }

    if (g_hCaptureTimer != null) {
        return;
    }

    int nTries = (g_cvCaptureTries != null) ? g_cvCaptureTries.IntValue : 12;
    if (nTries < 1) {
        nTries = 1;
    }

    float flStep = (g_cvCaptureStep != null) ? g_cvCaptureStep.FloatValue : 0.25;
    if (flStep < 0.05) {
        flStep = 0.05;
    }

    g_nCaptureSamplesLeft = nTries;
    g_flCaptureBest = 0.0;

    g_hCaptureTimer = CreateTimer(flStep, Timer_CaptureTick, 0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CaptureTick(Handle hTimer, any nData) {
    g_nCaptureSamplesLeft--;

    float flGameRecord = GR_GetFloat(GR_PROP_TEAM_BEST_ROUND_TIME);

    if (flGameRecord > g_flCaptureBest) {
        g_flCaptureBest = flGameRecord;
    }

    if ((g_cvDebug != null) && (g_cvDebug.IntValue > 0)) {
        DebugLog("CaptureTick: left=%d gameRecord=%.3f best=%.3ff", g_nCaptureSamplesLeft, flGameRecord, g_flCaptureBest);
    }

    if (g_nCaptureSamplesLeft > 0) {
        return Plugin_Continue;
    }

    g_hCaptureTimer = null;

    if (g_flCaptureBest > (g_flStoredRecord + 0.01)) {
        g_flStoredRecord = g_flCaptureBest;
        SaveRecordToFile(g_flStoredRecord);
        DebugLog("Saved new stored record %.3f", g_flStoredRecord);
    }
    else {
        DebugLog("No update. stored=%.3f capturedBest=%.3f", g_flStoredRecord, g_flCaptureBest);
    }

    ApplyStoredRecordNow();
    return Plugin_Stop;
}

// ================================================================
// Events
// ================================================================

public void Event_RoundStartPreEntity(Event hEvent, const char[] szName, bool bDontBroadcast) {
    ApplyStoredRecordNow();
}

public void Event_RoundStart(Event hEvent, const char[] szName, bool bDontBroadcast) {
    ApplyStoredRecordNow();
}

public void Event_SurvivalRoundStart(Event hEvent, const char[] szName, bool bDontBroadcast) {
    ApplyStoredRecordNow();
}

public void Event_RoundEnd(Event hEvent, const char[] szName, bool bDontBroadcast) {
    StartCaptureAfterRoundEnd();
}

// ================================================================
// Commands
// ================================================================

public Action Cmd_Apply(int nClient, int nArgs) {
    ApplyStoredRecordNow();
    ReplyToCommand(nClient, "%s applied stored record %.3f", CHAT_PREFIX, g_flStoredRecord);
    return Plugin_Handled;
}

public Action Cmd_Dump(int nClient, int nArgs) {
    float flRecord = GR_GetFloat(GR_PROP_TEAM_BEST_ROUND_TIME);

    ReplyToCommand(nClient, "%s map=%s stored=%.3f gamerules_record=%.3f start=%.3f end=%.3f", CHAT_PREFIX, g_szCurrentMap, g_flStoredRecord, flRecord);

    return Plugin_Handled;
}

public Action Cmd_Reset(int nClient, int nArgs) {
    g_flStoredRecord = 0.0;
    SaveRecordToFile(g_flStoredRecord);
    ApplyStoredRecordNow();

    ReplyToCommand(nClient, "%s record reset.", CHAT_PREFIX);
    return Plugin_Handled;
}

// ================================================================
// Entry points (last)
// ================================================================

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] szError, int nErrorMax) {
    if (GetEngineVersion() != Engine_Left4Dead2) {
        strcopy(szError, nErrorMax, "Plugin only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart() {
    g_cvEnable       = CreateConVar("l4d2_str_enable",        "1",    "Enable Survival Team Record persist.",                FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvPerMap       = CreateConVar("l4d2_str_per_map",       "1",    "1=per-map record, 0=global record.",                 FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCaptureTries = CreateConVar("l4d2_str_capture_tries", "12",   "How many capture samples after round end.",          FCVAR_NOTIFY, true, 1.0, true, 60.0);
    g_cvCaptureStep  = CreateConVar("l4d2_str_capture_step",  "0.25", "Seconds between capture samples.",                   FCVAR_NOTIFY, true, 0.05, true, 5.0);
    g_cvDebug        = CreateConVar("l4d2_str_debug",         "0",    "Debug logging.",                                     FCVAR_NOTIFY, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_survival_teamrecord_persist");

    g_cvGameMode = FindConVar("mp_gamemode");

    HookEvent("round_start_pre_entity", Event_RoundStartPreEntity, EventHookMode_PostNoCopy);
    HookEvent("round_start",            Event_RoundStart,         EventHookMode_PostNoCopy);
    HookEvent("survival_round_start",   Event_SurvivalRoundStart, EventHookMode_PostNoCopy);

    HookEvent("mission_lost", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("round_end",    Event_RoundEnd, EventHookMode_PostNoCopy);

    RegAdminCmd("sm_teamrecord_apply", Cmd_Apply, ADMFLAG_GENERIC, "Apply stored survival team record now.");
    RegAdminCmd("sm_teamrecord_dump",  Cmd_Dump,  ADMFLAG_GENERIC, "Dump stored and gamerules survival record values.");
    RegAdminCmd("sm_teamrecord_reset", Cmd_Reset, ADMFLAG_ROOT,    "Reset stored survival team record.");
}

public void OnMapStart() {
    BuildPaths();

    g_flStoredRecord = LoadRecordFromFile();

    StopCaptureTimer();
    g_nCaptureSamplesLeft = 0;
    g_flCaptureBest = 0.0;

    CreateTimer(0.20, Timer_ApplyOnMapStart, 0, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd() {
    StopCaptureTimer();
}

public Action Timer_ApplyOnMapStart(Handle hTimer, any nData) {
    ApplyStoredRecordNow();
    return Plugin_Stop;
}
