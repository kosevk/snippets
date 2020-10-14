# sqlserver-auto-check-for-missing-backups.sql

Requires: 
DBA database

Creates:
SQL Agent Job 
SQL Stored procedure


```sql

/*user params*/
    /*mandatory*/
    @recipient_mail NVARCHAR(800) = 'mail@mail.com'

    /*optional*/
    @defaul_mail_profile sysname = 'default_provile'

SELECT *, GETDATE() FROM sys.databases
WHERE 1=1
```