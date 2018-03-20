#include <amxmodx>
#include <sqlx>
#tryinclude <reapi>

#define CUSTOM_DEF_FLAG
	// Добавляет квар amx_default_access
	// Added cvar amx_default_access

// #define USE_DEFAULT_AMXX_FORWARD
	// Если используете fakemeta, не рекомендуется включать
	// Если есть ReAPI , то будет использоваться он, независимо от этой настройки
	// If you use fakemeta, do not turn it on
	// If there is ReAPI, then it will be used, regardless of this setting

#if !defined _reapi_included && !defined USE_DEFAULT_AMXX_FORWARD
	#include <fakemeta>
#endif
#if !defined MAX_PLAYERS
	#define MAX_PLAYERS 32
#endif
#if !defined MAX_NAME_LENGTH
	#define MAX_NAME_LENGTH 32
#endif

enum _:UserInfo	  { Auth[MAX_NAME_LENGTH], Passwd[64], Nick[MAX_NAME_LENGTH], Access, Flags, Expired } // g_sUser
enum _:ServerData { IP[24] } // g_szServerData
enum _:SqlData 	  { ServerInfo[32], Prefix[10] } // g_szSqlData

new Handle:g_hSqlTuple;
new g_Data[1], g_szQuery[512];

enum FWDS { AdminLoad, AdminLoad2 }
new g_fwdHandle[FWDS] = { INVALID_HANDLE, INVALID_HANDLE };

new g_iAdminExpired[MAX_PLAYERS + 1], g_iPlayerFlags[MAX_PLAYERS + 1];

new g_szServerData[ServerData];
new g_szSqlData[SqlData];

new Array:g_aUsers;
new g_sUser[UserInfo];

new g_szPassField[5];

new g_bitDefaultAccess = ADMIN_USER;
new g_iBanSystem;

new g_szBackupAdminPath[128];

public plugin_natives()
{
	register_library("Admin Loader");
	register_native("admin_expired", "admin_expired_callback", 1);
	register_native("al_get_access", "al_get_access_callback", 1);
}
public admin_expired_callback(id)
	return g_iAdminExpired[id];
	
public al_get_access_callback(id)
	return g_iPlayerFlags[id];

public plugin_end()
{
	SQL_FreeHandle(g_hSqlTuple);
	ArrayDestroy(g_aUsers);
}

public plugin_init()
{
#define PLUGIN_VERSION "3.1"
	register_plugin("Admin Loader", PLUGIN_VERSION, "neygomon");	
		// 1.7: add compatibility with Mazdan Admin Loader Forward
		// 1.8: refactoring code... Thanks Radius
		// 1.9: refactoring code... Мore readable code + added exec sql.cfg for compatibility with other mysql plugins
		// 2.0: refactoring code... Use Thread SQL Querys
		// 2.2: Fix bug with InfoChanged datas + added define USE_FAKEMETA
		// 2.3: Fix load BackUP without MySQL connection
		// 2.4: Add native al_get_access
		// 2.4.1: Close test connection
		// 2.4.2: Add cvar for indentification plugin =)
		// 2.5: Fix critical bug with access by IP 
		// 2.5.2: Fix #2 with IP bug
		// 2.6: Add reapi hookchain for changename
		// 2.6.1: Fix HookChain for reAPI
		// 2.6.2: May be fix error with invalid handle :D
		// 2.7: Add support field 'custom_flags'
		// 2.8: Optimization SQL query's... THX sonyx (https://neugomon.ru/members/62/)
		// 2.9: Fix compile on AMXX 182
		// 3.0: Forced use of ReAPI if available. New #define USE_DEFAULT_AMXX_FORWARD. Refactoring code...
		// 3.1: Fixed load backup if MySQL is not available
	
	register_concmd("amx_reloadadmins",    "cmdReload", ADMIN_CFG);
#if defined _reapi_included
	RegisterHookChain(RG_CBasePlayer_SetClientUserInfoName, "SetClientUserInfoName_Post", true);
#endif
#if !defined _reapi_included && !defined USE_DEFAULT_AMXX_FORWARD
	register_forward(FM_SetClientKeyValue, "SetCleintKeyValue_Post", true);
#endif
	new szPath[64], szPathFile[128];
	get_localinfo("amxx_configsdir", szPath, charsmax(szPath));
	
	formatex(szPathFile, charsmax(szPathFile), "%s/fb/main.cfg", szPath);
	if(file_exists(szPathFile))
		RegisterFreshBans(szPathFile);
	else
	{
		formatex(szPathFile, charsmax(szPathFile), "%s/LB/main.cfg", szPath);
		if(file_exists(szPathFile))
			RegisterLiteBans(szPathFile);
	} 
	if(!g_iBanSystem)
		set_fail_state("File main.cfg ban-systems Fresh Bans or Lite Bans not found!");
	
	RegisterDefaultCvars();
	ExecConfigs(szPath);
	ReadCvars();
	SqlInit();
	RegForwards();
}

public client_putinserver(id)
	UserAccess(id);
#if !defined _reapi_included && defined USE_DEFAULT_AMXX_FORWARD
public client_infochanged(id)
{
	if(!is_user_connected(id))
		return;

	new oldname[MAX_NAME_LENGTH];
	get_user_name(id, oldname, charsmax(oldname));
	
	new newname[MAX_NAME_LENGTH];
	get_user_info(id, "name", newname, charsmax(newname));
	
	if(strcmp(oldname, newname) != 0)
		UserAccess(id, newname);
}
#endif
#if defined _reapi_included
public SetClientUserInfoName_Post(const id, infobuffer[], szNewName[MAX_NAME_LENGTH])
	UserAccess(id, szNewName);
#endif
#if !defined _reapi_included && !defined USE_DEFAULT_AMXX_FORWARD
public SetCleintKeyValue_Post(id, const sInfoBuffer[], const sKey[], sValue[MAX_NAME_LENGTH])
	if(strcmp(sKey, "name") == 0)
		UserAccess(id, sValue);
#endif
public cmdReload(id, level)
{
	if(get_user_flags(id) & level)
		adminSql(id);
	return PLUGIN_HANDLED;
}

public SQL_Handler(failstate, Handle:query, err[], errcode, dt[], datasize)
{
	switch(failstate)
	{
		case TQUERY_CONNECT_FAILED, TQUERY_QUERY_FAILED:
		{
			log_amx("[SQL ERROR #%d][Query State %d] %s", errcode, dt[0], err);
			LoadBackUp();
			return;
		}
	}

	if(!SQL_NumResults(query))
	{
		log_amx("Администраторы для сервера %s не найдены!", g_szServerData[IP]); // Here is Original source
		/*log_amx("Administrators for the server %s not found!", g_szServerData[IP]); // This is english version*/
		return;
	}
	
	if(g_aUsers == Invalid_Array)
	{
		log_error(AMX_ERR_NOTFOUND, "Dyn massive g_aUsers invalid!");
		return;
	}

	new sBuffer[32];
	new iLoadAdmins;
	ArrayClear(g_aUsers);

	while(SQL_MoreResults(query))
	{
		SQL_ReadResult(query, 0, g_sUser[Auth], charsmax(g_sUser[Auth]));
		SQL_ReadResult(query, 1, g_sUser[Passwd], charsmax(g_sUser[Passwd]));
		SQL_ReadResult(query, 2, g_sUser[Nick], charsmax(g_sUser[Nick]));
				
		SQL_ReadResult(query, 6, sBuffer, charsmax(sBuffer)); trim(sBuffer); 
		if(!sBuffer[0]) SQL_ReadResult(query, 3, sBuffer, charsmax(sBuffer)); 
		g_sUser[Access] = read_flags(sBuffer);
		SQL_ReadResult(query, 4, sBuffer, charsmax(sBuffer)); g_sUser[Flags] = read_flags(sBuffer);
		g_sUser[Expired] = SQL_ReadResult(query, 5);

		ArrayPushArray(g_aUsers, g_sUser);
		iLoadAdmins++;
		SQL_NextRow(query);
	}

	new szText[128];
	if(iLoadAdmins == 1)
		formatex(szText, charsmax(szText), "Загружен 1 администратор из MySQL"); // Here is original source
		/*formatex(szText, charsmax(szText), "Uploaded 1 Administrator from MySQL"); // This is english version
	else 	formatex(szText, charsmax(szText), "Загружено %d администраторов из MySQL", iLoadAdmins); // Here is original source
	/*else	formatex(szText, charsmax(szText), "Uploaded %d Administators from MySQL", iLoadAdmins); // This is english version */

	if(dt[0] != 0) console_print(dt[0], szText);
	log_amx(szText);

	new pNum, players[MAX_PLAYERS];
	get_players(players, pNum);
	for(new i; i < pNum; i++)
		UserAccess(players[i]);
	BackUpAdmins();
}

public KickPlayer(const account[], id)
{
	new usr = get_user_userid(id);
	new szName[MAX_NAME_LENGTH]; get_user_name(id, szName, charsmax(szName));
	new szAuth[25]; get_user_authid(id, szAuth, charsmax(szAuth));
	new szIP[16];   get_user_ip(id, szIP, charsmax(szIP), 1);
	
	server_cmd("kick #%d Invalid password! Use setinfo ^"%s^" ^"your pass^"", usr, g_szPassField);
	log_amx("Login: ^"%s<%d><%s><>^" kicked due to invalid password (account ^"%s^") (address ^"%s^")",
		szName, usr, szAuth, account, szIP);
}

public LoadMapConfigs()
{
	new amxxcfgpath[64], map[32], fmt[64], prefix[32];
	get_localinfo("amxx_configsdir", amxxcfgpath, charsmax(amxxcfgpath));
	get_mapname(map, charsmax(map));
	formatex(fmt, charsmax(fmt), "%s/maps/%s.cfg", amxxcfgpath, map);
	if(file_exists(fmt)) ExecCfg(fmt);
	else
	{
		strtok(map, prefix, charsmax(prefix), "", 0, '_');
		formatex(fmt, charsmax(fmt), "%s/maps/prefix_%s.cfg", amxxcfgpath, prefix);
		if(file_exists(fmt)) ExecCfg(fmt);
	}
}

adminSql(id)
{
	g_Data[0] = id;

	formatex(g_szQuery, charsmax(g_szQuery), "SELECT \
		`a`.`steamid`, \
		`a`.`password`, \
		`a`.`nickname`, \
		`a`.`access`, \
		`a`.`flags`, \
		`a`.`expired`, \
		`b`.`custom_flags` \
		FROM `%s_amxadmins` AS `a`, `%s_admins_servers` AS `b` \
		WHERE `b`.`admin_id` = `a`.`id` \
                AND `b`.`server_id` = (SELECT `id` FROM `%s` WHERE `address` = '%s') \
                AND (`a`.`days` = '0' OR `a`.`expired` > UNIX_TIMESTAMP(NOW()))",
		g_szSqlData[Prefix], g_szSqlData[Prefix], g_szSqlData[ServerInfo], g_szServerData[IP]
        );
		
	SQL_ThreadQuery(g_hSqlTuple, "SQL_Handler", g_szQuery, g_Data, sizeof(g_Data));	
}

UserAccess(id, name[MAX_NAME_LENGTH] = "")
{
	remove_user_flags(id);

	new authid[25]; get_user_authid(id, authid, charsmax(authid));
	new ip[16];     get_user_ip(id, ip, charsmax(ip), 1);
	if(!name[0])    get_user_name(id, name, charsmax(name));

	for(new i, sFlags[30], Hash[34], password[33], aSize = ArraySize(g_aUsers); i < aSize; i++)
	{
		ArrayGetArray(g_aUsers, i, g_sUser);
		
		if(g_sUser[Flags] & FLAG_AUTHID)
		{
			if(strcmp(authid, g_sUser[Auth]) != 0)
				continue;
		}
		else if(g_sUser[Flags] & FLAG_IP)
		{
			if(strcmp(ip, g_sUser[Auth]) != 0)
				continue;
		}
		else if(strcmp(name, g_sUser[Auth]) != 0)
			continue;
		
		g_iAdminExpired[id] = g_sUser[Expired];
		get_flags(g_sUser[Access], sFlags, charsmax(sFlags));
			
		if(g_sUser[Flags] & FLAG_NOPASS)
		{
			g_iPlayerFlags[id] = g_sUser[Access];
				
			set_user_flags(id, g_sUser[Access]);
			ExecuteFwd(id, g_sUser[Access], g_sUser[Expired]);
			log_amx("Login: ^"%s<%d><%s><>^" became an admin (account ^"%s^") (nickname ^"%s^") (access ^"%s^") (address ^"%s^")",
				name, get_user_userid(id), authid, g_sUser[Auth], g_sUser[Nick], sFlags, ip);
		}
		else
		{
			get_user_info(id, g_szPassField, password, charsmax(password));
		#if AMXX_VERSION_NUM >= 183
			hash_string(password, Hash_Md5, Hash, charsmax(Hash));
		#else
			md5(password, Hash);
		#endif
			if(strcmp(Hash, g_sUser[Passwd]) == 0)
			{
				set_user_flags(id, g_sUser[Access]);
				ExecuteFwd(id, g_sUser[Access], g_sUser[Expired]);
				log_amx("Login: ^"%s<%d><%s><>^" became an admin (account ^"%s^") (nickname ^"%s^") (access ^"%s^") (address ^"%s^")",
					name, get_user_userid(id), authid, g_sUser[Auth], g_sUser[Nick], sFlags, ip);
			}
			else if(g_sUser[Flags] & FLAG_KICK)
				set_task(0.2, "KickPlayer", id, g_sUser[Auth], sizeof g_sUser[Auth]);
		}
		return PLUGIN_HANDLED;
	}
  
	g_iAdminExpired[id] = -1;
	g_iPlayerFlags[id]  = g_bitDefaultAccess;
	set_user_flags(id, g_bitDefaultAccess);
	ExecuteFwd(id, g_bitDefaultAccess, g_iAdminExpired[id]);
	return PLUGIN_HANDLED;
}

RegisterDefaultCvars()
{
	register_cvar("amx_votekick_ratio", "0.40");
	register_cvar("amx_voteban_ratio", "0.40");
	register_cvar("amx_votemap_ratio", "0.40");
	register_cvar("amx_vote_ratio", "0.02");
	register_cvar("amx_vote_time", "10");
	register_cvar("amx_vote_answers", "1");
	register_cvar("amx_vote_delay", "60");
	register_cvar("amx_last_voting", "0");
	register_cvar("amx_show_activity", "2",   FCVAR_PROTECTED);
	register_cvar("amx_password_field", "_pw",FCVAR_PROTECTED);
#if defined CUSTOM_DEF_FLAG	
	register_cvar("amx_default_access", "z",  FCVAR_PROTECTED);
#endif
	register_cvar("admin_loader_version", PLUGIN_VERSION, FCVAR_SERVER | FCVAR_SPONLY);
}

RegisterSqlCfg()
{
	register_cvar("amx_sql_table", "admins",   FCVAR_PROTECTED);
	register_cvar("amx_sql_host", "127.0.0.1", FCVAR_PROTECTED);
	register_cvar("amx_sql_user", "root",      FCVAR_PROTECTED);
	register_cvar("amx_sql_pass", "",          FCVAR_PROTECTED);
	register_cvar("amx_sql_db", "amx",         FCVAR_PROTECTED);
	register_cvar("amx_sql_type", "mysql",     FCVAR_PROTECTED);
}

RegisterFreshBans(fbcfg[]) // This can work with FreshBans
{
	g_iBanSystem = 1;
	register_cvar("fb_sql_host", "", FCVAR_PROTECTED);
	register_cvar("fb_sql_user", "", FCVAR_PROTECTED);
	register_cvar("fb_sql_pass", "", FCVAR_PROTECTED);
	register_cvar("fb_sql_db", "",   FCVAR_PROTECTED);
	register_cvar("fb_servers_table", "", FCVAR_PROTECTED);
	register_cvar("fb_server_ip", "");
	register_cvar("fb_server_port", "");
	ExecCfg(fbcfg);
}

RegisterLiteBans(lbcfg[]) // This can work with LiteBans
{
	g_iBanSystem = 2;
	register_cvar("lb_sql_host", "", FCVAR_PROTECTED);
	register_cvar("lb_sql_user", "", FCVAR_PROTECTED);
	register_cvar("lb_sql_pass", "", FCVAR_PROTECTED);
	register_cvar("lb_sql_db", "",   FCVAR_PROTECTED);
	register_cvar("lb_sql_pref", "", FCVAR_PROTECTED);
	register_cvar("lb_server_ip", "");
	ExecCfg(lbcfg);
}

ExecConfigs(amxxcfgdir[])
{
	new szFullDir[128];
	formatex(szFullDir, charsmax(szFullDir), "%s/amxx.cfg", amxxcfgdir);
	ExecCfg(szFullDir);
	formatex(szFullDir, charsmax(szFullDir), "%s/sql.cfg", amxxcfgdir);
	RegisterSqlCfg(); ExecCfg(szFullDir);
	
	formatex(g_szBackupAdminPath, charsmax(g_szBackupAdminPath), "%s/users.ini", amxxcfgdir);
}

ReadCvars()
{
	get_cvar_string("amx_password_field", g_szPassField, charsmax(g_szPassField));
#if defined CUSTOM_DEF_FLAG
	new szDefaultAccess[32]; 
	get_cvar_string("amx_default_access", szDefaultAccess, charsmax(szDefaultAccess));
	g_bitDefaultAccess = read_flags(szDefaultAccess);
#endif
	set_cvar_float("amx_last_voting", 0.0);
#if AMXX_VERSION_NUM < 183	
	set_task(6.1, "LoadMapConfigs");
#endif
}

RegForwards()
{
	for(new plId, plNum = get_pluginsnum(); plId < plNum; plId++) 
	{
		if(g_fwdHandle[AdminLoad] == INVALID_HANDLE)
		{
			if(get_func_id("client_admin", plId) != -1)
				g_fwdHandle[AdminLoad] = CreateMultiForward("client_admin", ET_IGNORE, FP_CELL, FP_CELL);
		}
		else if(g_fwdHandle[AdminLoad2] == INVALID_HANDLE)
		{
			if(get_func_id("amxx_admin_access", plId) != -1)
				g_fwdHandle[AdminLoad2] = CreateMultiForward("amxx_admin_access", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
		}
	}
}

SqlInit()
{
	new sHost[32], sUser[32], sPasswd[64], sDbName[32];
	switch(g_iBanSystem)
	{
		case 1:
		{
			get_cvar_string("fb_sql_host", sHost,   charsmax(sHost));
			get_cvar_string("fb_sql_user", sUser,   charsmax(sUser));
			get_cvar_string("fb_sql_pass", sPasswd, charsmax(sPasswd));
			get_cvar_string("fb_sql_db",   sDbName, charsmax(sDbName));
			
			new ip[16];  get_cvar_string("fb_server_ip", ip, charsmax(ip));
			new port[8]; get_cvar_string("fb_server_port", port, charsmax(port));
			formatex(g_szServerData[IP], charsmax(g_szServerData[IP]), "%s:%s", ip, port);
			
			get_cvar_string("fb_servers_table", g_szSqlData[ServerInfo], charsmax(g_szSqlData[ServerInfo]));
			strtok(g_szSqlData[ServerInfo], g_szSqlData[Prefix], charsmax(g_szSqlData[Prefix]), "", 0, '_');
		}
		case 2:
		{
			get_cvar_string("lb_sql_host", sHost,   charsmax(sHost));
			get_cvar_string("lb_sql_user", sUser,   charsmax(sUser));
			get_cvar_string("lb_sql_pass", sPasswd, charsmax(sPasswd));
			get_cvar_string("lb_sql_db",   sDbName, charsmax(sDbName));
		
			get_cvar_string("lb_server_ip", g_szServerData[IP],   charsmax(g_szServerData[IP]));
			get_cvar_string("lb_sql_pref", g_szSqlData[Prefix], charsmax(g_szSqlData[Prefix]));
			
			formatex(g_szSqlData[ServerInfo], charsmax(g_szSqlData[ServerInfo]), "%s_serverinfo", g_szSqlData[Prefix]);
		}	
	}

	g_aUsers = ArrayCreate(UserInfo);
	
	SQL_SetAffinity("mysql");
	g_hSqlTuple = SQL_MakeDbTuple(sHost, sUser, sPasswd, sDbName, 1);

	
	new errcode, errstr[128], Handle:hSqlTest = SQL_Connect(g_hSqlTuple, errcode, errstr, charsmax(errstr));
	if(hSqlTest == Empty_Handle)
	{
		log_amx("[SQL ERROR #%d] %s", errcode, errstr);
		LoadBackUp();
	}	
	else
	{
		SQL_FreeHandle(hSqlTest);
	#if AMXX_VERSION_NUM >= 183
		SQL_SetCharset(g_hSqlTuple, "utf8");
	#endif
		adminSql(0);
	}	
}

ExecCfg(const cfg[])
{
	server_cmd("exec %s", cfg);
	server_exec();
}

ExecuteFwd(id, flags, timestamp)
{
	new ret;
	if(g_fwdHandle[AdminLoad] != INVALID_HANDLE)
		ExecuteForward(g_fwdHandle[AdminLoad], ret, id, flags);
	if(g_fwdHandle[AdminLoad2] != INVALID_HANDLE)
		ExecuteForward(g_fwdHandle[AdminLoad2], ret, id, flags, timestamp);	
}

BackUpAdmins()
{
	unlink(g_szBackupAdminPath);
	
	new fp = fopen(g_szBackupAdminPath, "w+");
	new szDate[30]; get_time("%d.%m.%Y - %H:%M:%S", szDate, charsmax(szDate));
	if(!fprintf(fp, "; BackUP SQL admins. Date %s ^n^n", szDate))
	{
		fclose(fp);
		return;
	}
	for(new i, sAFlags[30], sCFlags[10], aSize = ArraySize(g_aUsers); i < aSize; i++)
	{
		ArrayGetArray(g_aUsers, i, g_sUser);
		get_flags(g_sUser[Access], sAFlags, charsmax(sAFlags));
		get_flags(g_sUser[Flags], sCFlags, charsmax(sCFlags));
		
		fprintf(fp, 
			"^"%s^" ^"%s^" ^"%s^" ^"%s^" ^"%s^" ^"%d^"^n", 
				g_sUser[Auth], g_sUser[Passwd], sAFlags, sCFlags, g_sUser[Nick], g_sUser[Expired]
		);
	}
	fclose(fp);
}

LoadBackUp()
{
	new fp = fopen(g_szBackupAdminPath, "rt");
	if(!fp)
	{
		new szError[190];
		formatex(szError, charsmax(szError), "File '%s' not found OR chmod not correct!", g_szBackupAdminPath);
		set_fail_state(szError);
	}
	
	new szBuffer[200];
	new szBuff[3][64];
	new load;
	while(!feof(fp))
	{
		fgets(fp, szBuffer, charsmax(szBuffer));
		trim(szBuffer);
		
		if(!szBuffer[0] || szBuffer[0] == ';')
			continue;
			
		if(parse(szBuffer, 
			g_sUser[Auth], charsmax(g_sUser[Auth]), 
			g_sUser[Passwd], charsmax(g_sUser[Passwd]), 
			szBuff[0], charsmax(szBuff[]), 
			szBuff[1], charsmax(szBuff[]), 
			g_sUser[Nick], charsmax(g_sUser[Nick]), 
			szBuff[2], charsmax(szBuff[])
			) == 6
		)
		{
			g_sUser[Access] = read_flags(szBuff[0]);
			g_sUser[Flags] 	= read_flags(szBuff[1]);
			g_sUser[Expired]= str_to_num(szBuff[2]);
			
			ArrayPushArray(g_aUsers, g_sUser);
			load++;
		}
	}
	fclose(fp);
	log_amx("[Admin Loader] Загружен %d %s из BackUP users.ini", load, load == 1 ? "администратор" : "администраторов"); // Here is original source
	/*log_amx("[Admin Loader] Uploaded %d %s from BackUP users.ini", load, load == 1 ? "admin" : "admins"); // This is english version */
}
