enum _:ADS_STRUCT {
	ADS__AUTHID[MAX_AUTHID_LENGTH],
	ADS__FLAGS,
	ADS__FIRST_NAME[MAX_NAME_LENGTH],
	ADS__LAST_NAME[MAX_NAME_LENGTH],
	ADS__FIRST_DAY,
	ADS__LAST_DAY,
	ADS__UNIQUE_DAYS,
	ADS__TIME
};

/**
 * Called before account with non-zero online will be added to list.
 *
 * @return      PLUGIN_CONTINUE to allow adding to list
 *              PLUGIN_HANDLED to prevent adding to list
 */
forward OnlineLogger_OnAddingInList(const eAccountData[ADS_STRUCT], bool:bAutoGen);

/**
 * Called before account with zero online will be added to list.
 *
 * @return      PLUGIN_CONTINUE to allow adding to list
 *              PLUGIN_HANDLED to prevent adding to list
 */
forward OnlineLogger_OnAddingZeroAcc(const szAuthID[], iAccessFlags, bool:bAutoGen);

/**
 * Called to request player session online time (so you can use your own logic for it).
 *
 * @return      PLUGIN_CONTINUE to let system use default logic (get_user_time() native)
 *              PLUGIN_HANDLED to use your own value (you must set iSessionTime)
 */
forward OnlineLogger_RequestSessionTime(pPlayer, &iSessionTime);