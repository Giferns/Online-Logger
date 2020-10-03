/* История изменений:
	1.0 (03.10.2020) by mx?!:
		* Первый релиз
*/

new const PLUGIN_VERSION[] = "1.0"

/* -------------------- */

#include <amxmodx>
#include <online_logger>

#define chx charsmax

new g_iTeamChar[MAX_PLAYERS + 1] = { 'U', ... }
new g_iGameStartTime[MAX_PLAYERS + 1]
new g_iSavedGameTime[MAX_PLAYERS + 1]

/* -------------------- */

public plugin_init() {
	register_plugin("Real Game Time", PLUGIN_VERSION, "mx?!")

	register_event("TeamInfo", "event_TeamInfo", "a")
}

/* -------------------- */

public event_TeamInfo() {
	new pPlayer = read_data(1)
	new szNewTeam[2]; read_data(2, szNewTeam, chx(szNewTeam))

	if(g_iTeamChar[pPlayer] == szNewTeam[0]) {
		return
	}

	switch(szNewTeam[0]) {
		case 'U', 'S': {
			if(g_iGameStartTime[pPlayer]) {
				g_iSavedGameTime[pPlayer] += get_systime() - g_iGameStartTime[pPlayer]
				g_iGameStartTime[pPlayer] = 0
			}
		}
		case 'T', 'C': {
			if(!g_iGameStartTime[pPlayer]) {
				g_iGameStartTime[pPlayer] = get_systime()
			}
		}
	}

	g_iTeamChar[pPlayer] = szNewTeam[0]
}

/* -------------------- */

public client_connect(pPlayer) {
	g_iSavedGameTime[pPlayer] = 0
}

/* -------------------- */

public OnlineLogger_RequestSessionTime(pPlayer, &iSessionTime) {
	iSessionTime = g_iSavedGameTime[pPlayer]

	if(g_iGameStartTime[pPlayer]) {
		iSessionTime += get_systime() - g_iGameStartTime[pPlayer]
	}

	return PLUGIN_HANDLED
}