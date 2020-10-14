/*user params*/
    /*mandatory*/
    @recipient_mail NVARCHAR(800) = 'mail@mail.com'

    /*optional*/
    @defaul_mail_profile sysname = 'default_provile'

USE [msdb]
GO

IF NOT EXISTS (SELECT TOP(1) name FROM msdb.dbo.sysjobs WHERE name = 'BackupFlow.SimpleCheck')
BEGIN
EXEC  msdb.dbo.sp_add_job @job_name=N'BackupFlow.SimpleCheck', 
		@enabled=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=2, 
		@notify_level_page=2, 
		@delete_level=0, 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa';

EXEC msdb.dbo.sp_add_jobserver @job_name=N'BackupFlow.SimpleCheck', @server_name = @@SERVERNAME;

EXEC msdb.dbo.sp_add_jobstep @job_name=N'BackupFlow.SimpleCheck', @step_name=N'check for missing backups', 
		@step_id=1, 
		@cmdexec_success_code=0, 
		@on_success_action=1, 
		@on_fail_action=2, 
		@retry_attempts=0, 
		@retry_interval=0, 
		@os_run_priority=0, @subsystem=N'TSQL', 
		@command=N'EXEC DBA.dbo.BackupFlow_simpleCheck', 
		@database_name=N'DBA', 
		@flags=0;
EXEC msdb.dbo.sp_update_job @job_name=N'BackupFlow.SimpleCheck', 
		@enabled=1, 
		@start_step_id=1, 
		@notify_level_eventlog=0, 
		@notify_level_email=2, 
		@notify_level_page=2, 
		@delete_level=0, 
		@description=N'', 
		@category_name=N'[Uncategorized (Local)]', 
		@owner_login_name=N'sa', 
		@notify_email_operator_name=N'', 
		@notify_page_operator_name=N'';

IF NOT EXISTS (SELECT TOP(1) name FROM msdb.dbo.sysschedules WHERE name = 'BackupFlow.SimpleCheck')
BEGIN
	EXEC msdb.dbo.sp_add_jobschedule @job_name=N'BackupFlow.SimpleCheck', @name=N'BackupFlow.SimpleCheck', 
			@enabled=1, 
			@freq_type=4, 
			@freq_interval=1, 
			@freq_subday_type=1, 
			@freq_subday_interval=0, 
			@freq_relative_interval=0, 
			@freq_recurrence_factor=1, 
			@active_start_date=20201007, 
			@active_end_date=99991231, 
			@active_start_time=70000, 
			@active_end_time=235959
	END
END

USE DBA
GO
IF OBJECT_ID('dbo.BackupFlow_simpleCheck') IS NULL
  EXEC ('CREATE PROCEDURE dbo.BackupFlow_simpleCheck AS RETURN 0;');
GO

ALTER PROCEDURE dbo.BackupFlow_simpleCheck
WITH RECOMPILE
AS
BEGIN
/*declare variables to be used*/
DECLARE @server_name sysname = (SELECT @@SERVERNAME)
DECLARE @result table (name sysname)
DECLARE @count_results INT
DECLARE @database_in_aoag TABLE (name sysname, ag_replicate_state NVARCHAR(10))

/*get info for secondary databases in AG groups*/
IF EXISTS (SELECT * FROM sys.system_views WHERE name LIKE 'dm_hadr_availability_group_states')
BEGIN

;WITH database_ag_state AS (
SELECT  DISTINCT
        sd.name
      , (CASE
             WHEN hdrs.is_primary_replica IS NULL THEN 'none'
             WHEN EXISTS ( SELECT * FROM  sys.dm_hadr_database_replica_states AS irs
                   WHERE sd.database_id = irs.database_id
                            AND is_primary_replica = 1 ) THEN 'primary'
             ELSE 'secondary'
         END) AS ag_replicate_state
FROM                sys.databases AS sd
LEFT OUTER JOIN sys.dm_hadr_database_replica_states AS hdrs
    ON hdrs.database_id = sd.database_id )
	INSERT INTO @database_in_aoag
	(name, ag_replicate_state )
	SELECT database_ag_state.name
         , database_ag_state.ag_replicate_state FROM database_ag_state
		 WHERE database_ag_state.ag_replicate_state = 'secondary'


END 


/*check if there are databases where D backup is older than 7 days*/
INSERT INTO @result
SELECT d.name
FROM master.sys.databases d
LEFT OUTER JOIN msdb.dbo.backupset b 
ON d.name COLLATE SQL_Latin1_General_CP1_CI_AS = b.database_name COLLATE SQL_Latin1_General_CP1_CI_AS
AND b.type = 'D'
AND b.server_name = SERVERPROPERTY('ServerName')
LEFT JOIN @database_in_aoag ag
ON ag.name = d.name
WHERE 1=1
AND d.database_id <> 2
AND d.is_in_standby = 0
AND d.state NOT IN(1, 6, 10)
AND d.source_database_id IS NULL
AND d.name NOT IN ('add_databases_to_exclude')
AND ag.ag_replicate_state IS NULL
GROUP BY d.name
HAVING  MAX(b.backup_finish_date) <= DATEADD(dd,-7, GETDATE())
    OR MAX(b.backup_finish_date) IS NULL;	

/*if there are missing backups, then send an email*/
IF EXISTS (SELECT TOP(1) name FROM @result)
BEGIN
SET @count_results = (SELECT COUNT(*) FROM @result)



    /*HTML variables*/
    DECLARE @HTML_BODY NVARCHAR(MAX)
    DECLARE @xml_result NVARCHAR(MAX)
    DECLARE @HTML_subject NVARCHAR(500) = (SELECT CAST(@count_results AS NVARCHAR(3)) + ' database backup/s missing on ' + @server_name )
    DECLARE @msdb_profile_name NVARCHAR(100) = (SELECT @defaul_mail_profile)
	/*check if default profile is there, if not get the oldest*/
	IF NOT EXISTS (SELECT TOP(1) name FROM msdb.dbo.sysmail_profile
    WHERE name = @defaul_mail_profile)
    BEGIN
    SET @msdb_profile_name = (SELECT TOP(1) name FROM msdb.dbo.sysmail_profile ORDER BY profile_id)
    END



    SET @xml_result = 
        CAST( 
            (SELECT name AS 'td', '' FROM @result FOR XML raw('tr'), elements, type)        
            AS nvarchar(MAX))

    set @HTML_BODY =
   '<html><head><style>
    BODY {background-color:#FFFFFF; line-height:1px; -webkit-text-size-adjust:none; color: #000000; font-family: sans-serif;}
        H1 {font-size: 90%; color: #000000;}
        H2 {font-size: 90%; color: #000000;}
        H3 {color: #000000;}                  
        TABLE, TD, TH {
            font-size: 87%;
            border: 1px solid #000000;
            border-collapse: collapse;
        }                        
        TH {
            font-size: 87%;
            text-align: left;
            background-color: #e3e3e3;
            color: #000000;
            padding: 4px;
            padding-left: 7px;
            padding-right: 7px;
        }
        TD {
            font-size: 87%;
            padding: 4px;
            padding-left: 7px;
            padding-right: 7px;
            max-width: 100px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }
    </style></head><body>

    <p style="font-family:sans-serif; font-size:20px; color:#ff0030;">No full backups in the last 7 days.</p>
    <table border="1">
            <tr>
                <th>Database name</th>
            </tr>'
            
    + @xml_result + '</table>'

	/*send the email*/
    EXEC msdb.dbo.sp_send_dbmail  
    @profile_name = @msdb_profile_name,  
    @recipients = 'mail@mail',  
    @body = @HTML_BODY,  
    @subject = @HTML_subject,
    @body_format = 'HTML';  

END
END
GO