-- Every file of every database this login may open (CONNECT ANY DATABASE),
-- from each database's own sys.database_files: sys.master_files, which
-- has them all, needs a wider right (VIEW ANY DEFINITION).
DECLARE @f TABLE (database_id int NOT NULL, file_id int NOT NULL, kind nvarchar(10) NOT NULL, name nvarchar(128) NOT NULL,
    pages bigint NOT NULL, max_pages bigint NOT NULL, growth bigint NOT NULL, pct_growth bit NOT NULL, PRIMARY KEY (database_id, file_id));
DECLARE @fsql nvarchar(max) = N'';
SELECT @fsql = @fsql + N' UNION ALL SELECT ' + CONVERT(nvarchar(10), database_id)
    + N', file_id, CASE type WHEN 1 THEN N''log'' ELSE N''data'' END, name, size, max_size, growth, is_percent_growth FROM '
    + QUOTENAME(name) + N'.sys.database_files'
FROM sys.databases WHERE state = 0 AND user_access = 0 AND HAS_DBACCESS(name) = 1;
IF LEN(@fsql) > 0
BEGIN
    SET @fsql = STUFF(@fsql, 1, 11, N'');
    INSERT @f EXEC sys.sp_executesql @fsql;
END;
