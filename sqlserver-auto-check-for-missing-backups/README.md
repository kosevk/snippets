# sqlserver-auto-check-for-missing-backups.sql

## Requires: 
>DBA database

## Creates:

> SQL Agent Job , SQL Stored procedure

## Modifications required:

```sql
/*change the following to suit your needs*/
/*default_profile_name*/
DECLARE @msdb_profile_name NVARCHAR(100) = (SELECT 'default_profile_name')
...
/*default_profile_name*/
WHERE name = 'default_profile_name')
...
/*mail@mail.com*/
EXEC msdb.dbo.sp_send_dbmail  
@profile_name = @msdb_profile_name, 
@recipients = 'mail@mail.com',
```

# Does:

User stored procedure **dbo.BackupFlow_simpleCheck** is created within database DBA, that checks for databases with full backup older than 7 days, and if such is found, send an email to defined email;

SQL Agent job **BackupFlow.SimpleCheck** automates this, performing the check every morning;

The part where a check is made also excludes snapshots, databases in state we dont like and secondary databases in availability groups;

```sql 
/*temp table to hold ag data, not every server has ag configured*/
DECLARE @database_in_aoag TABLE (name sysname, ag_replicate_state NVARCHAR(10))

/*see if there are ag objects, add them to the temp table*/
IF EXISTS (SELECT * FROM sys.system_views WHERE name LIKE 'dm_hadr_availability_group_states')
BEGIN
    ;WITH database_ag_state AS (
    SELECT DISTINCT sd.name
        , (CASE
                WHEN hdrs.is_primary_replica IS NULL THEN 'none'
                WHEN EXISTS ( SELECT * FROM  sys.dm_hadr_database_replica_states AS irs
                    WHERE sd.database_id = irs.database_id
                          AND is_primary_replica = 1 ) THEN 'primary'
                ELSE 'secondary'
            END) AS ag_replicate_state
    FROM sys.databases AS sd
    LEFT OUTER JOIN sys.dm_hadr_database_replica_states AS hdrs
        ON hdrs.database_id = sd.database_id )
        INSERT INTO @database_in_aoag
        (name, ag_replicate_state )
        SELECT database_ag_state.name
            , database_ag_state.ag_replicate_state FROM database_ag_state
            WHERE database_ag_state.ag_replicate_state = 'secondary'
END 

/*select me the databases in proper state that does not have full backups in the last 7 days, also skip tempdb, snapshots and ag secondaries*/
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

```