/* История изменений:
	28.03.18 by mx?!:
		* Первый релиз
	06.04.18 by mx?!:
		* Теперь записи заносятся в файл начиная с учётки с самым большим онлайном, и далее по убыванию
		* Теперь плагин так же заносит в список все активные учётки (с авторизацией по steamid), имеющие нулевой онлайн
		* Теперь к имени файла списка будет добавляться текущий год
		* Добавлена поддержка MultiLang (хардкод клиентских сообщений убран, серверных, - нет)
		* Небольшие правки кода и комментариев, пара незначительных багфиксов
	04.11.19 by mx?!:
		* Форматирование списка теперь производится с использованием html
		* Теперь записи в списке сортируются по убыванию времени онлайна
	1.0.3 (29.09.2020) by mx?!:
		* Переход на семантическое версионирование, базовая версия плагина - 1.0.3
		* Убрана поддержка AMXX < 183
		* Реализовано API
		* Полный MultiLang
		* Рефакторинг, упразднение части функционала
		* Добавлен авто-конфиг, часть настроек переведена на квары
		* ВНИМАНИЕ! Хранилище данных несовместимо со старыми версиями плагина.
			Перед обновлением рекомендуется удалить старое хранилище (смотрите VAULT_NAME).
*/

new const PLUGIN_VERSION[] = "1.0.3"

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <reapi>
#include <time>
#include <online_logger>

/* ---------------------- НАСТРОЙКИ ---------------------- */

// Создавать конфиг с кварами в 'configs/plugins', и запускать его?
#define AUTO_CFG

// Лимит выборки записей из хранилища при генерации списка
const ACCOUNT_LIMIT = 256 // Увеличить, если в списке появится соответствующий запрос

// Флаг доступа к функции ручного создания лога (впоследствии можно поменять в amxmodx/configs/cmdaccess.ini)
const ACCESS_FLAG = ADMIN_RCON // ADMIN_RCON == 'l', см. amxconst.inc

// Команда ручной генерации лога
new const FORCE_CMD[] = "amx_make_log"

// Список клиентских команд просмотра собственного времени онлайна
new const CLCMDS[][] = {
	"say /myonline"
}

// Имя-шаблон (без расширения) для создаваемых логов админ-онлайна
new const LOG_PREFIX[] = "" // при таком варианте имя будет иметь вид %ГОД%_%НОМЕР_МЕСЯЦА%.%LOG_EXT%
//new const LOG_PREFIX[] = "month_" // month_%ГОД%_%НОМЕР_МЕСЯЦА%.%LOG_EXT%

// Постфикс, добавляемый после номера месяца при генерации списка в ручном режиме
new const MANUAL_POSTFIX[] = "_manual" // %ГОД%_%НОМЕР_МЕСЯЦА%_manual.%LOG_EXT%

// Расширение для логов админ-онлайна
// Теоретически FASTDL может не позволять скачивать файлы конкретного расширения из
// 	конкретных директорий. Экспериментируйте с комбинациями, подбирайте под себя.
new const LOG_EXT[] = ".html"
//new const LOG_EXT[] = ".dat" // Работает на MultiPlay при #define LOGS_DIR "online_logs"
//new const LOG_EXT[] = ".bsp" // Пс, парень, хочешь обмануть FASTDL?

// Путь+имя папки, в которой будут размещаться логи админ-онлайна
// Папка создаётся автоматически в момент создания лога, однако, я настоятельно
// рекомендую создать её вручную, и выставить доступ на запись
new const LOGS_DIR[] = "online_logs" // В корне мода (cstrike)
//new const LOGS_DIR[] = "addons/amxmodx/logs/online_logs"
//new const LOGS_DIR[] = "maps/online_logs"

// Имя хранилища (addons/amxmodx/data/vault/%NAME%.vault)
new const VAULT_NAME[] = "online_logs"

// Имя файла (с расширением), хранящего порядковый номер текущего месяца (addons/amxmodx/data/%NAME%)
new const DATE_FILE_NAME[] = "ol_date.txt"

/* ---------------------- НАСТРОЙКИ ---------------------- */

#if !defined is_user_authorized
	native is_user_authorized(pPlayer)
#endif

#define chx charsmax
#define chx_len(%0) charsmax(%0) - iLen

#define MAX_VAULT_TEXT_LENGTH 128
#define MAX_TIME_STRING_LENGTH 64
#define MAX_TIME_LENGTH 9

stock const SOUND__BLIP1[] = "sound/buttons/blip1.wav"
stock const SOUND__ERROR[] = "sound/buttons/button2.wav"

enum DATE_UNIT_ENUM {
	DATE_UNIT__MONTHDAY,
	DATE_UNIT__YEARDAY,
	DATE_UNIT__YEAR
}

enum { // ol_clcmd_mode cvar states
	CLCMD__DISABLED,
	CLCMD__DEFAULT,
	CLCMD__REQ_FLAGS,
	CLCMD__DENY_FLAGS
}

enum _:CVAR_ENUM {
	CVAR__LOG_FLAGS[32],
	CVAR__IGNORE_FLAGS[32],
	CVAR__CLCMD_FLAGS[32],
	CVAR__CLCMD_MODE,
	CVAR__FASTDL[128]
}

new g_eCvar[CVAR_ENUM]
new g_iTime[MAX_PLAYERS + 1]
new g_hVault = INVALID_HANDLE
new g_iCurMonth
new g_hFwdRequestTime

/* -------------------- */

public plugin_init() {
	register_plugin("Online Logger", PLUGIN_VERSION, "mx?!")
	register_dictionary("online_logger.txt")

	func_RegCvars()

	register_concmd(FORCE_CMD, "func_MakeLog", ACCESS_FLAG)

	for(new i; i < sizeof(CLCMDS); i++) {
		register_clcmd(CLCMDS[i], "func_CheckOnline")
	}

	g_hFwdRequestTime = CreateMultiForward("OnlineLogger_RequestSessionTime", ET_STOP, FP_CELL, FP_VAL_BYREF)

	date(.month = g_iCurMonth)
}

/* -------------------- */

public plugin_cfg() {
	func_CheckMonth()
	func_OpenVault()
}

/* -------------------- */

func_RegCvars() {
	bind_cvar_string( "ol_log_flags", "d",
		.desc = "Flags ('any of' requirement) to log player online",
		.bind = g_eCvar[CVAR__LOG_FLAGS], .maxlen = chx(g_eCvar[CVAR__LOG_FLAGS])
	);

	bind_cvar_string( "ol_ignore_flags", "",
		.desc = "Flags ('any of' requirement) to skip loging (leave empty to disable)",
		.bind = g_eCvar[CVAR__IGNORE_FLAGS], .maxlen = chx(g_eCvar[CVAR__IGNORE_FLAGS])
	);

	bind_cvar_string( "ol_clcmd_flags", "",
		.desc = "Flags ('any of' requirement) for ol_clcmd_mode cvar behavior",
		.bind = g_eCvar[CVAR__CLCMD_FLAGS], .maxlen = chx(g_eCvar[CVAR__CLCMD_FLAGS])
	);

	bind_cvar_num( "ol_clcmd_mode", "1",
		.desc =
		"Clcmd mode:^n\
		0 - Disable clcmd^n\
		1 - ol_clcmd_flags not used^n\
		2 - Allow if player have any flag from ol_clcmd_flags^n\
		3 - Block if player have any flag from ol_clcmd_flags",
		.has_min = true, .min_val = 0.0, .has_max = true, .max_val = 3.0,
		.bind = g_eCvar[CVAR__CLCMD_MODE]
	);

	bind_cvar_string( "ol_fastdl_url", "",
		.desc = "FastDL URL (mirror mode required! leave empty if unsure)",
		.bind = g_eCvar[CVAR__FASTDL], .maxlen = chx(g_eCvar[CVAR__FASTDL])
	);

#if defined AUTO_CFG
	AutoExecConfig(/*.name = "PluginName"*/)
#endif
}

/* -------------------- */

func_CheckMonth() {
	new szPath[PLATFORM_MAX_PATH]
	new iLen = get_datadir(szPath, chx(szPath))
	formatex(szPath[iLen], chx_len(szPath), "/%s", DATE_FILE_NAME)

	new hFile = fopen(szPath, "r")

	if(!hFile) {
		if(file_exists(szPath)) {
			set_fail_state("Can't read '%s'", szPath)
		}

		func_WriteDateFile(szPath)
		return
	}

	new szMonth[4]
	fgets(hFile, szMonth, chx(szMonth))
	fclose(hFile)

	new iPrevMonth = str_to_num(szMonth)

	if(g_iCurMonth == iPrevMonth) {
		return
	}

	func_WriteDateFile(szPath)

	formatex(szPath[iLen], chx_len(szPath), "/vault/%s_%i.vault", VAULT_NAME, iPrevMonth)

	if(file_exists(szPath)) {
		func_GenerateLog(iPrevMonth, szPath, .bAutoGen = true)
		delete_file(szPath)
	}
}

/* -------------------- */

func_WriteDateFile(const szPath[]) {
	new hFile = fopen(szPath, "w")

	if(!hFile) {
		set_fail_state("Can't write '%s'", szPath)
	}

	fprintf(hFile, "%i", g_iCurMonth)
	fclose(hFile)
}

/* -------------------- */

func_OpenVault() {
	g_hVault = nvault_open( fmt("%s_%i", VAULT_NAME, g_iCurMonth) )

	if(g_hVault == INVALID_HANDLE) {
		set_fail_state("Can't open vault!")
	}
}

/* -------------------- */

public func_CheckOnline(pPlayer) {
	if(!is_user_authorized(pPlayer) || g_eCvar[CVAR__CLCMD_MODE] == CLCMD__DISABLED) {
		return PLUGIN_HANDLED
	}

	new iFlags = get_user_flags(pPlayer)

	new iLogFlags = read_flags(g_eCvar[CVAR__LOG_FLAGS])
	new iIgnoreFlags = read_flags(g_eCvar[CVAR__IGNORE_FLAGS])

	if( !(iFlags & iLogFlags) || (iFlags & iIgnoreFlags) ) {
		rg_send_audio(pPlayer, SOUND__ERROR)
		client_print_color(pPlayer, print_team_red, "%l", "OL_NO_LOGGING_MSG")
		return PLUGIN_HANDLED
	}

	switch(g_eCvar[CVAR__CLCMD_MODE]) {
		case CLCMD__REQ_FLAGS: {
			if( !(iFlags & read_flags(g_eCvar[CVAR__CLCMD_FLAGS])) ) {
				func_NoAccess(pPlayer)
				return PLUGIN_HANDLED
			}
		}
		case CLCMD__DENY_FLAGS: {
			if(iFlags & read_flags(g_eCvar[CVAR__CLCMD_FLAGS])) {
				func_NoAccess(pPlayer)
				return PLUGIN_HANDLED
			}
		}
	}

	if(!g_iTime[pPlayer]) {
		new szAuthID[MAX_AUTHID_LENGTH]
		get_user_authid(pPlayer, szAuthID, chx(szAuthID))
		func_LoadData(pPlayer, szAuthID, .bJustPrint = true)
		return PLUGIN_HANDLED
	}

	func_PrintTime(pPlayer)
	return PLUGIN_HANDLED
}

/* -------------------- */

func_NoAccess(pPlayer) {
	rg_send_audio(pPlayer, SOUND__ERROR)
	client_print_color(pPlayer, print_team_red, "%l", "OL_NO_ACCESS_MSG")
}

/* -------------------- */

func_PrintTime(pPlayer) {
	rg_send_audio(pPlayer, SOUND__BLIP1)

	static szTimeString[MAX_TIME_STRING_LENGTH]
	func_FormatTimeString(pPlayer, max(0, g_iTime[pPlayer] + func_GetSessionTime(pPlayer)), szTimeString)

	client_print_color(pPlayer, print_team_default, "%l", "OL_ONLINE_MSG", szTimeString)
}

/* -------------------- */

func_LoadData(pPlayer, const szAuthID[], bool:bJustPrint) {
	static szVaultText[MAX_VAULT_TEXT_LENGTH], iTimeStamp

	if(nvault_lookup(g_hVault, szAuthID, szVaultText, chx(szVaultText), iTimeStamp)) {
		func_ParseData(pPlayer, szVaultText, szAuthID, bJustPrint)
		return
	}

	if(bJustPrint) {
		g_iTime[pPlayer] = -1
		func_PrintTime(pPlayer)
		return
	}

	new iMonthDay = func_GetDate(DATE_UNIT__MONTHDAY)

	new szName[MAX_NAME_LENGTH]
	get_user_name(pPlayer, szName, chx(szName))

	func_SaveData(pPlayer, func_GetDate(DATE_UNIT__YEARDAY), 1, iMonthDay, iMonthDay, 0, szAuthID, szName, szName)
}

/* -------------------- */

func_ParseData(pPlayer, const szVaultText[], const szAuthID[], bool:bJustPrint) {
	static szYearDay[5], szUniqueDays[3], szFirstDay[3],
		szFirstName[MAX_NAME_LENGTH], szLastName[MAX_NAME_LENGTH], szTime[MAX_TIME_LENGTH]

	parse( szVaultText,
		szYearDay, chx(szYearDay),
		szUniqueDays, chx(szUniqueDays),
		szFirstDay, chx(szFirstDay),
		"",	"",
		szTime, chx(szTime),
		szFirstName, chx(szFirstName)
	);

	new iYearDay = str_to_num(szYearDay)
	new iActualYearDay = func_GetDate(DATE_UNIT__YEARDAY)
	new iUniqueDays = str_to_num(szUniqueDays)

	if(iYearDay != iActualYearDay) {
		iUniqueDays++
		iYearDay = iActualYearDay
	}

	if(bJustPrint) {
		g_iTime[pPlayer] = str_to_num(szTime)
		func_PrintTime(pPlayer)
		return
	}

	//else ->
	get_user_name(pPlayer, szLastName, chx(szLastName))

	func_SaveData( pPlayer, iYearDay, iUniqueDays, str_to_num(szFirstDay),
		func_GetDate(DATE_UNIT__MONTHDAY), str_to_num(szTime), szAuthID, szFirstName, szLastName );
}

/* -------------------- */

func_SaveData(pPlayer, iYearDay, iUniqueDays, iFirstDay, iCurrentDay, iTime, const szAuthID[], const szFirstName[], const szLastName[]) {
	static szVaultText[MAX_VAULT_TEXT_LENGTH]

	formatex( szVaultText, chx(szVaultText),
		"%i %i %i %i %i ^"%s^" ^"%s^" %i",
		iYearDay, iUniqueDays, iFirstDay, iCurrentDay,
		iTime + func_GetSessionTime(pPlayer), szFirstName, szLastName, get_user_flags(pPlayer)
	);

	nvault_set(g_hVault, szAuthID, szVaultText)
}

/* -------------------- */

public client_disconnected(pPlayer) {
	if(!is_user_connected(pPlayer) || !is_user_authorized(pPlayer)) {
		return
	}

	g_iTime[pPlayer] = 0

	new iFlags = get_user_flags(pPlayer)
	new iLogFlags = read_flags(g_eCvar[CVAR__LOG_FLAGS])
	new iIgnoreFlags = read_flags(g_eCvar[CVAR__IGNORE_FLAGS])

	if( !(iFlags & iLogFlags) || (iFlags & iIgnoreFlags) ) {
		return
	}

	static szAuthID[MAX_AUTHID_LENGTH]
	szAuthID[0] = EOS
	get_user_authid(pPlayer, szAuthID, chx(szAuthID))

	if(szAuthID[0] == 'S' || szAuthID[0] == 'V') {
		func_LoadData(pPlayer, szAuthID, .bJustPrint = false)
	}
}

/* -------------------- */

func_GetDate(DATE_UNIT_ENUM:iMode) {
	static const szDateType[DATE_UNIT_ENUM][] = { "%d", "%j", "%Y" }
	static szDate[5]
	get_time(szDateType[iMode], szDate, chx(szDate))
	return str_to_num(szDate)
}

/* -------------------- */

public func_MakeLog(pPlayer, iAccess) {
	if(pPlayer) {
		if( !(get_user_flags(pPlayer) & iAccess) ) {
			return PLUGIN_HANDLED
		}

		static Float:fGenTime
		new Float:fGameTime = get_gametime()

		if(fGameTime - fGenTime < 10.0) {
			rg_send_audio(pPlayer, SOUND__ERROR)
			console_print(pPlayer, "%L", func_GetLang(pPlayer), "OL_NO_SPAM")
			return PLUGIN_HANDLED
		}

		fGenTime = fGameTime
	}

	console_print(pPlayer, "%L", func_GetLang(pPlayer), "OL_START_GEN")

	new szPath[PLATFORM_MAX_PATH]
	new iLen = get_datadir(szPath, chx(szPath))
	formatex(szPath[iLen], chx_len(szPath), "/vault/%s_%i.vault", VAULT_NAME, g_iCurMonth)

	nvault_close(g_hVault)
	func_GenerateLog(g_iCurMonth, szPath, .bAutoGen = false)
	func_OpenVault()

	if(!g_eCvar[CVAR__FASTDL][0]) {
		console_print(pPlayer, "%L", func_GetLang(pPlayer), "OL_GEN_DONE_NO_LINK", LOGS_DIR)
	}
	else {
		new szLink[PLATFORM_MAX_PATH]

		formatex( szLink, chx(szLink), "%s/%s/%s%i_%02d%s%s", g_eCvar[CVAR__FASTDL], LOGS_DIR, LOG_PREFIX,
			func_GetDate(DATE_UNIT__YEAR), g_iCurMonth, MANUAL_POSTFIX, LOG_EXT );

		console_print(pPlayer, "%L", func_GetLang(pPlayer), "OL_GEN_DONE_WITH_LINK", szLink)
	}

	return PLUGIN_HANDLED
}

/* -------------------- */

func_GetLang(pPlayer) {
	new szLang[3]

	if(pPlayer) {
		new iLen = get_user_info(pPlayer, "lang", szLang, chx(szLang))

		if(!iLen) {
			static pCvar

			if(!pCvar) {
				pCvar = get_cvar_pointer("amx_language")
			}

			get_pcvar_string(pCvar, szLang, chx(szLang))
		}
	}
	else {
		copy(szLang, chx(szLang), "en")
	}

	return szLang
}

/* -------------------- */

func_GetSessionTime(pPlayer) {
	new iRet, iSessionTime

	ExecuteForward(g_hFwdRequestTime, iRet, pPlayer, iSessionTime)

	if(!iRet) {
		iSessionTime = get_user_time(pPlayer, 1)
	}

	return iSessionTime
}

/* -------------------- */

#define MAX_KEY_LEN MAX_AUTHID_LENGTH		// Max 255
#define MAX_VAL_LEN MAX_VAULT_TEXT_LENGTH	// Max 65535
#define DATA_BUFFER MAX_VAULT_TEXT_LENGTH	// Make this the greater of (MAX_KEY_LEN / 4) or (MAX_VAL_LEN / 4)

enum _:POINTER_STRUCT {
	POINTER__ID,
	POINTER__TIME
}

func_GenerateLog(iMonth, const szVaultPath[], bool:bAutoGen) {
	new hVault = fopen(szVaultPath, "rb")

   	if(!hVault) {
		set_fail_state("Can't binary-read '%s'", szVaultPath)
	}

	new szPath[PLATFORM_MAX_PATH]

	formatex( szPath, chx(szPath), "%s/%s%i_%02d%s%s", LOGS_DIR, LOG_PREFIX, func_GetDate(DATE_UNIT__YEAR),
		iMonth, bAutoGen ? "" : MANUAL_POSTFIX, LOG_EXT );

	if(!dir_exists(LOGS_DIR) && mkdir(LOGS_DIR) == -1) {
		fclose(hVault)
		set_fail_state("Can't make dir '%s'", LOGS_DIR)
	}

	new hFile = fopen(szPath, "w")

	if(!hFile) {
		fclose(hVault)
		set_fail_state("Can't write '%s'", szPath)
	}

	new szString[MAX_VAULT_TEXT_LENGTH]

	new iVaultEntries, iKeyLen, iValLen, szVal[MAX_VAL_LEN + 1]

	new	Trie:tTrie = TrieCreate()
	new	Array:aArray = ArrayCreate(ADS_STRUCT)
	new eAccountData[ADS_STRUCT], iPtrData[ACCOUNT_LIMIT][POINTER_STRUCT]

	fread_raw(hVault, szString, 1, BLOCK_INT)
	fread_raw(hVault, szString, 1, BLOCK_SHORT)
	fread_raw(hVault, szString, 1, BLOCK_INT)
	iVaultEntries = szString[0]

	new szLang[3]
	get_cvar_string("amx_language", szLang, chx(szLang))

	get_time("%H:%M:%S", szString, chx(szString))

	new iYear, iMonth, iDay
	date(iYear, iMonth, iDay)

	fprintf( hFile, "<meta charset=utf-8><title>Online Logger - %02d.%02d.%i (%L)</title>^n",
		iDay, iMonth, iYear, szLang, bAutoGen ? "OL_AUTO" : "OL_MANUAL" );

	new szTime[MAX_TIME_LENGTH]

	fprintf( hFile, "%L", szLang, "OL_LOG_1", szLang, bAutoGen ? "OL_AUTO" : "OL_MANUAL",
		iMonth, iYear, szLang, "OL_GENERATED", iDay, iMonth, szString );

	fprintf(hFile, "^n%L", szLang, "OL_LOG_2", g_eCvar[CVAR__LOG_FLAGS])

	new szFlags[32] = "N/A"
	if(g_eCvar[CVAR__IGNORE_FLAGS][0]) {
		copy(szFlags, chx(szFlags), g_eCvar[CVAR__IGNORE_FLAGS])
	}

	fprintf(hFile, "^n%L", szLang, "OL_LOG_3", szFlags)

	fprintf(hFile, "^n%L", szLang, "OL_LOG_4", iVaultEntries, ACCOUNT_LIMIT)

	if(iVaultEntries > ACCOUNT_LIMIT) {
		fprintf(hFile, "^n%L^n%L", szLang, "OL_LOG_5", szLang, "OL_LOG_6")
		iVaultEntries = ACCOUNT_LIMIT
	}

	new szUniqueDays[3], szFirstDay[3], szLastDay[3], iFlags

	new iLogFlags = read_flags(g_eCvar[CVAR__LOG_FLAGS])
	new iIgnoreFlags = read_flags(g_eCvar[CVAR__IGNORE_FLAGS])

	for(new i, a; i < iVaultEntries; i++) {
		// TimeStamp
		fread_raw(hVault, szString, 1, BLOCK_INT)

		// Key Length
		fread_raw(hVault, szString, 1, BLOCK_BYTE)
		iKeyLen = szString[0] & 0xFF

		// Val Length
		fread_raw(hVault, szString, 1, BLOCK_SHORT)
		iValLen = szString[0] & 0xFFFF

		// Key Data
		fread_raw(hVault, szString, iKeyLen, BLOCK_CHAR)
		func_ReadString(eAccountData[ADS__AUTHID], iKeyLen, chx(eAccountData[ADS__AUTHID]), szString)

		// Val Data
		fread_raw(hVault, szString, iValLen, BLOCK_CHAR)
		func_ReadString(szVal, iValLen, chx(szVal), szString)

		parse( szVal,
			"", "",
			szUniqueDays, chx(szUniqueDays),
			szFirstDay, chx(szFirstDay),
			szLastDay, chx(szLastDay),
			szTime, chx(szTime),
			eAccountData[ADS__FIRST_NAME], chx(eAccountData[ADS__FIRST_NAME]),
			eAccountData[ADS__LAST_NAME], chx(eAccountData[ADS__LAST_NAME]),
			szFlags, chx(szFlags) // here we got flags as bitsum
		);

		iFlags = str_to_num(szFlags)

		if( !(iFlags & iLogFlags) || (iFlags & iIgnoreFlags) ) {
			continue
		}

		eAccountData[ADS__FLAGS] = iFlags
		eAccountData[ADS__UNIQUE_DAYS] = str_to_num(szUniqueDays)
		eAccountData[ADS__FIRST_DAY] = str_to_num(szFirstDay)
		eAccountData[ADS__LAST_DAY] = str_to_num(szLastDay)

		iPtrData[a][POINTER__TIME] = eAccountData[ADS__TIME] = str_to_num(szTime)
		iPtrData[a][POINTER__ID] = a++

		ArrayPushArray(aArray, eAccountData)
		TrieSetCell(tTrie, eAccountData[ADS__AUTHID], 0)
	}

	fclose(hVault)

	SortCustom2D(iPtrData, sizeof(iPtrData), "func_SortTime")

	new const szDivider[] = "^n<br>==================================================================================="

	new iRet, hFwd = CreateMultiForward("OnlineLogger_OnAddingInList", ET_STOP, FP_ARRAY, FP_CELL)

	new szTimeString[MAX_TIME_STRING_LENGTH], iWritedCount
	new szFirstName[MAX_NAME_LENGTH * 4], szLastName[MAX_NAME_LENGTH * 4]

	new iArraySize = ArraySize(aArray)

	new hArrayHandle = PrepareArray(eAccountData, sizeof(eAccountData))

	for(new i; i < iArraySize; i++) {
		ArrayGetArray(aArray, iPtrData[i][POINTER__ID], eAccountData)

		ExecuteForward(hFwd, iRet, hArrayHandle, bAutoGen)

		if(iRet) {
			continue
		}

		fputs(hFile, szDivider)

		copy(szFirstName, chx(szFirstName), eAccountData[ADS__FIRST_NAME])
		copy(szLastName, chx(szLastName), eAccountData[ADS__LAST_NAME])
		htmlspecialchars(szFirstName, chx(szFirstName))
		htmlspecialchars(szLastName, chx(szLastName))

		func_FormatTimeString(0, eAccountData[ADS__TIME], szTimeString)

		get_flags(eAccountData[ADS__FLAGS], szFlags, chx(szFlags))

		fprintf( hFile,
			"^n%L^n\
			%L^n\
			%L^n\
			%L^n\
			%L",

			szLang, "OL_LOG_7", ++iWritedCount, eAccountData[ADS__AUTHID], szFlags,
			szLang, "OL_LOG_8", szFirstName, szLastName,
			szLang, "OL_LOG_9", eAccountData[ADS__FIRST_DAY], eAccountData[ADS__LAST_DAY],
			szLang, "OL_LOG_10", eAccountData[ADS__UNIQUE_DAYS],
			szLang, "OL_LOG_11", szTimeString
		);
	}

	DestroyForward(hFwd)

	fputs(hFile, szDivider)

	fprintf(hFile, "^n%L", szLang, "OL_LOG_12", iWritedCount, iArraySize - iWritedCount)

	fprintf(hFile, "^n%L", szLang, "OL_LOG_13")

	hFwd = CreateMultiForward("OnlineLogger_OnAddingZeroAcc", ET_STOP, FP_STRING, FP_CELL, FP_CELL)

	new iSkipped
	iWritedCount = 0

	for(new i, szAuthID[MAX_AUTHID_LENGTH], iCount = admins_num(); i < iCount; i++) {
		if( !(admins_lookup(i, AdminProp_Flags) & FLAG_AUTHID) ) {
			continue
		}

		admins_lookup(i, AdminProp_Auth, szAuthID, chx(szAuthID))

		if(TrieKeyExists(tTrie, szAuthID)) {
			continue
		}

		iFlags = admins_lookup(i, AdminProp_Access)

		if( !(iFlags & iLogFlags) || (iFlags & iIgnoreFlags) ) {
			continue
		}

		ExecuteForward(hFwd, iRet, szAuthID, iFlags, bAutoGen)

		if(iRet) {
			iSkipped++
			continue
		}

		get_flags(iFlags, szFlags, chx(szFlags))

		fprintf(hFile, "^n%L", szLang, "OL_LOG_7", ++iWritedCount, szAuthID, szFlags)
	}

	DestroyForward(hFwd)

	fputs(hFile, szDivider)

	fprintf(hFile, "^n%L", szLang, "OL_LOG_12", iWritedCount, iSkipped)

	fclose(hFile)
	TrieDestroy(tTrie)
	ArrayDestroy(aArray)
}

/* -------------------- */

public func_SortTime(eElement1[], eElement2[]) {
	if(eElement1[POINTER__TIME] < eElement2[POINTER__TIME])
		return 1

	if(eElement1[POINTER__TIME] > eElement2[POINTER__TIME])
		return -1

	return 0
}

/* -------------------- */

func_ReadString(szDestString[], iLen, iMaxLen, SourceData[]) {
	new iStrPos = -1, iRawPos

	while((++iStrPos < iLen) && (iStrPos < iMaxLen) && (iRawPos < DATA_BUFFER)) {
		szDestString[iStrPos] = (SourceData[iRawPos] >> ((iStrPos % 4) * 8)) & 0xFF

		if(iStrPos && ((iStrPos % 4) == 3)) {
			iRawPos++
		}
	}

	szDestString[iStrPos] = EOS
}

/* -------------------- */

enum _:TIME_TYPES {
	TYPE_WEEK,
	TYPE_DAY,
	TYPE_HOUR,
	TYPE_MIN,
	TYPE_SEC
}

func_FormatTimeString(pPlayer, iSec, szTimeString[MAX_TIME_STRING_LENGTH]) {
	new iCount, iType[TIME_TYPES]

	iType[TYPE_WEEK] = iSec / SECONDS_IN_WEEK
	iSec -= (iType[TYPE_WEEK] * SECONDS_IN_WEEK)

	iType[TYPE_DAY] = iSec / SECONDS_IN_DAY
	iSec -= (iType[TYPE_DAY] * SECONDS_IN_DAY)

	iType[TYPE_HOUR] = iSec / SECONDS_IN_HOUR
	iSec -= (iType[TYPE_HOUR] * SECONDS_IN_HOUR)

	iType[TYPE_MIN] = iSec / SECONDS_IN_MINUTE
	iType[TYPE_SEC] = iSec -= (iType[TYPE_MIN] * SECONDS_IN_MINUTE)

	static const szLang[][] = { "OL_TIME_WEEK", "OL_TIME_DAY", "OL_TIME_HOUR", "OL_TIME_MIN", "OL_TIME_SEC" }

	static szElement[TIME_TYPES][12]

	for(new i; i < sizeof(iType); i++) {
		if(iType[i] > 0) {
			formatex(szElement[iCount++], chx(szElement[]), "%i %L", iType[i], pPlayer, szLang[i])
		}
	}

	static const szAndChar[] = "OL_TIME_AND"

	switch(iCount) {
		case 0: formatex(szTimeString, chx(szTimeString), "0 %L", pPlayer, szLang[TYPE_SEC])
		case 1: copy(szTimeString, chx(szTimeString), szElement[0])
		case 2: formatex(szTimeString, chx(szTimeString), "%s %L %s", szElement[0], pPlayer, szAndChar, szElement[1])
		case 3: formatex(szTimeString, chx(szTimeString), "%s, %s, %L %s", szElement[0], szElement[1], pPlayer, szAndChar, szElement[2])
		case 4: formatex(szTimeString, chx(szTimeString), "%s, %s, %s, %L %s", szElement[0], szElement[1], szElement[2], pPlayer, szAndChar, szElement[3])
		case 5: formatex(szTimeString, chx(szTimeString), "%s, %s, %s, %s, %L %s", szElement[0], szElement[1], szElement[2], szElement[3], pPlayer, szAndChar, szElement[4])
	}
}

/* -------------------- */

public plugin_end() {
	if(g_hVault != INVALID_HANDLE) {
		nvault_close(g_hVault)
	}
}

/* -------------------- */

// https://www.php.net/manual/ru/function.htmlspecialchars.php
stock htmlspecialchars(szString[], iMaxLen) {
	static const szReplaceWhat[][] = { "&", "^"", "'", "<", ">" }
	static const szReplaceWith[][] = { "&amp;", "&quot;", "&#039;", "&lt;", "&gt;" }

	for(new i; i < sizeof(szReplaceWhat); i++) {
		replace_string(szString, iMaxLen, szReplaceWhat[i], szReplaceWith[i])
	}
}

/* -------------------- */

stock bind_cvar_num(const cvar[], const value[], flags = FCVAR_NONE, const desc[] = "", bool:has_min = false, Float:min_val = 0.0, bool:has_max = false, Float:max_val = 0.0, &bind) {
	bind_pcvar_num(create_cvar(cvar, value, flags, desc, has_min, min_val, has_max, max_val), bind)
}

stock bind_cvar_float(const cvar[], const value[], flags = FCVAR_NONE, const desc[] = "", bool:has_min = false, Float:min_val = 0.0, bool:has_max = false, Float:max_val = 0.0, &Float:bind) {
	bind_pcvar_float(create_cvar(cvar, value, flags, desc, has_min, min_val, has_max, max_val), bind)
}

stock bind_cvar_string(const cvar[], const value[], flags = FCVAR_NONE, const desc[] = "", bool:has_min = false, Float:min_val = 0.0, bool:has_max = false, Float:max_val = 0.0, bind[], maxlen) {
	bind_pcvar_string(create_cvar(cvar, value, flags, desc, has_min, min_val, has_max, max_val), bind, maxlen)
}

stock bind_cvar_num_by_name(const szCvarName[], &iBindVariable) {
	bind_pcvar_num(get_cvar_pointer(szCvarName), iBindVariable)
}