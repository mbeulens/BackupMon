del /S "D:\SyntecServer\backup\mysql\backup.logdata.%DATE:~0,3%.rar"
D:\SyntecServer\mysql\bin\mysqldump --defaults-extra-file="D:\SyntecServer\backup\mysql-creds.cnf" --single-transaction=TRUE  --result-file="D:\SyntecServer\backup\mysql\backup.logdata.%DATE:~0,3%.sql" syntec  s_tab_log a_msg a_msg_ses s_usage s_usage_archive s_ses _ses_tok s_sys_log mv_s_prt mv_a_car s_mail_queue
"C:\Program Files\WinRAR\rar.exe" a -r "D:\SyntecServer\backup\mysql\backup.logdata.%DATE:~0,3%.rar" "D:\SyntecServer\backup\mysql\backup.logdata.%DATE:~0,3%.sql"
del /S "D:\SyntecServer\backup\mysql\backup.logdata.%DATE:~0,3%.sql"
robocopy D:\SyntecServer\backup\mysql \\ponnas001\Syntec_Backup\mysql /E