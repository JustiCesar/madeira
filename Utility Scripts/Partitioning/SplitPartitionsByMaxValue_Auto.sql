/*
SELECT
  DB_NAME() AS database_name
, pf.name AS partition_function
, pf.type_desc AS partition_function_type
, pf.boundary_value_on_right
, pf.fanout
, ps.name AS partition_scheme
, fg.name AS partition_filegroup
, OBJECT_SCHEMA_NAME(c.object_id) AS table_schema_name
, OBJECT_NAME(c.object_id) AS table_name
, ix.name AS index_name
, c.name AS column_name
, tp.name AS column_type
, c.max_length, c.precision, c.scale, c.collation_name
, rv.boundary_id, rv.value, p.rows
FROM sys.partitions AS p
INNER JOIN sys.indexes AS ix ON p.object_id = ix.object_id AND p.index_id = ix.index_id
INNER JOIN sys.partition_schemes AS ps ON ix.data_space_id = ps.data_space_id
INNER JOIN sys.partition_functions AS pf ON ps.function_id = pf.function_id
INNER JOIN sys.destination_data_spaces dds ON p.partition_number = dds.destination_id AND ps.data_space_id = dds.partition_scheme_id
INNER JOIN sys.filegroups AS fg ON dds.data_space_id = fg.data_space_id
INNER JOIN sys.partition_range_values AS rv ON rv.function_id = pf.function_id AND rv.boundary_id = p.partition_number
INNER JOIN sys.index_columns AS ic ON ic.object_id = p.object_id AND ic.index_id = ix.index_id AND ic.partition_ordinal > 0
INNER JOIN sys.columns AS c ON c.object_id = p.object_id AND c.column_id = ic.column_id
INNER JOIN sys.types AS tp ON c.system_type_id = tp.system_type_id AND c.user_type_id = tp.user_type_id
--WHERE pf.name = 'MyPartitionFunctionName'
ORDER BY partition_function, partition_scheme, table_schema_name, table_name, index_name, boundary_id
*/
GO
/*
===============================================================
Author: Eitan Blumin | https://eitanblumin.com | https://madeiradata.com
Date: 2022-01-11
Minimum Version: SQL Server 2016 (13.x) and later
===============================================================

-- Example 1: Automatically detect current max value, and create 200 buffer partitions beyond it, using the last interval as the increment:

EXEC dbo.[SplitPartitionsByMaxValue]
	  @RoundRobinFileGroups = 'FG_Partitions_1,FG_Partitions_2'
	, @PartitionFunctionName = 'MyPartitionFunctionName'
	, @TargetRangeValue = NULL
	, @BufferIntervals = 200
	, @DebugOnly = 0

GO

-- Example 2: Create monthly partitions one year forward:

DECLARE @FutureValue datetime = DATEADD(year,1, CONVERT(date, GETDATE()))

EXEC dbo.[SplitPartitionsByMaxValue]
	  @RoundRobinFileGroups = 'PRIMARY'
	, @PartitionFunctionName = 'MyMonthlyPartitionFunctionName'
	, @TargetRangeValue = @FutureValue
	, @PartitionIncrementExpression = 'DATEADD(MM, 1, CONVERT(datetime, @CurrentRangeValue))'
	, @DebugOnly = 0
*/
CREATE OR ALTER PROCEDURE dbo.[SplitPartitionsByMaxValue]
  @RoundRobinFileGroups nvarchar(MAX) = N'PRIMARY'
, @PartitionFunctionName sysname
, @TargetRangeValue sql_variant = NULL
, @PartitionIncrementExpression nvarchar(4000) = N'CONVERT(float, @CurrentRangeValue) + CONVERT(float, @PartitionRangeInterval)' -- 'DATEADD(MM, 1, CONVERT(datetime, @CurrentRangeValue))'
, @BufferIntervals int = 100
, @PartitionRangeInterval sql_variant = NULL
, @DebugOnly bit = 0
AS
BEGIN

SET NOCOUNT, ARITHABORT, XACT_ABORT, QUOTED_IDENTIFIER ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
DECLARE @FileGroups AS table (FGID int NOT NULL IDENTITY(1,1), FGName sysname NOT NULL);
DECLARE @Msg nvarchar(max);

INSERT INTO @FileGroups (FGName)
SELECT DISTINCT RTRIM(LTRIM([value]))
FROM STRING_SPLIT(@RoundRobinFileGroups, N',')

IF @@ROWCOUNT = 0
BEGIN
	RAISERROR(N'At least one filegroup must be specified in @RoundRobinFileGroups',16,1);
	RETURN -1;
END

SELECT @Msg = ISNULL(@Msg + N', ', N'') + FGName
FROM @FileGroups
WHERE FGName NOT IN (SELECT ds.name FROM sys.data_spaces AS ds WHERE ds.type = 'FG'))

IF @Msg IS NOT NULL
BEGIN
	RAISERROR(N'Invalid filegroup(s) specified: %s', 16, 1, @Msg);
	RETURN -1;
END

DECLARE
  @MaxPartitionRangeValue sql_variant
, @CurrentRangeCount int
, @LastPartitionNumber int
, @PartitionKeyDataType sysname
, @CMD nvarchar(max)
, @MaxValueFromTable sysname
, @MaxValueFromColumn sysname
, @ActualMaxValue sql_variant


SELECT TOP (1)
  @CurrentRangeCount = pf.fanout
, @LastPartitionNumber = p.partition_number
, @MaxPartitionRangeValue = rv.value
, @MaxValueFromColumn = c.name
, @MaxValueFromTable = QUOTENAME(OBJECT_SCHEMA_NAME(p.object_id)) + N'.' + QUOTENAME(OBJECT_NAME(p.object_id))
, @PartitionKeyDataType = QUOTENAME(tp.[name])
+ CASE
	WHEN tp.name LIKE '%char%' OR tp.name LIKE '%binary%' THEN N'(' + ISNULL(CONVERT(nvarchar(MAX), NULLIF(c.max_length,-1)),'max') + N')'
	WHEN tp.name IN ('decimal', 'numeric') THEN N'(' + CONVERT(nvarchar(MAX), c.precision) + N',' + CONVERT(nvarchar(MAX), c.scale) + N')'
	WHEN tp.name IN ('datetime2') THEN N'(' + CONVERT(nvarchar(MAX), c.scale) + N')'
	ELSE N''
  END
FROM sys.partitions AS p
INNER JOIN sys.indexes AS ix ON p.object_id = ix.object_id AND p.index_id = ix.index_id
INNER JOIN sys.partition_schemes AS ps ON ix.data_space_id = ps.data_space_id
INNER JOIN sys.partition_functions AS pf ON ps.function_id = pf.function_id
INNER JOIN sys.partition_range_values AS rv ON rv.function_id = pf.function_id AND rv.boundary_id = p.partition_number
INNER JOIN sys.index_columns AS ic ON ic.object_id = p.object_id AND ic.index_id = p.index_id AND ic.partition_ordinal > 0
INNER JOIN sys.columns AS c ON c.object_id = p.object_id AND c.column_id = ic.column_id
INNER JOIN sys.types AS tp ON c.system_type_id = tp.system_type_id AND c.user_type_id = tp.user_type_id
WHERE pf.name = @PartitionFunctionName
ORDER BY CASE WHEN p.rows > 0 THEN 0 ELSE 1 END ASC, p.partition_number DESC


IF @PartitionRangeInterval IS NULL AND @PartitionIncrementExpression IS NULL
BEGIN
	SET @CMD = N'
	SELECT TOP (1)
		@PartitionRangeInterval = CONVERT(sql_variant, CONVERT(' + @PartitionKeyDataType + N', @MaxPartitionRangeValue) - CONVERT(' + @PartitionKeyDataType + N', rv.value))
	FROM sys.partition_range_values AS rv
	INNER JOIN sys.partition_functions AS f ON rv.function_id = f.function_id
	WHERE f.name = @PartitionFunctionName
	AND rv.boundary_id < @LastPartitionNumber
	ORDER BY rv.boundary_id DESC'

	EXEC sp_executesql @CMD
		, N'@PartitionRangeInterval sql_variant OUTPUT, @MaxPartitionRangeValue sql_variant, @PartitionFunctionName sysname, @LastPartitionNumber int'
		, @PartitionRangeInterval OUTPUT, @MaxPartitionRangeValue, @PartitionFunctionName, @LastPartitionNumber
END

SET @PartitionIncrementExpression = ISNULL(@PartitionIncrementExpression, N'CONVERT(float, @CurrentRangeValue) + CONVERT(float, @PartitionRangeInterval)')

DECLARE @MissingIntervals float;

IF @ActualMaxValue IS NULL
BEGIN
	SET @CMD = N'SELECT @ActualMaxValue = CONVERT(sql_variant, MAX(' + @MaxValueFromColumn + N')) FROM ' + @MaxValueFromTable;
	EXEC sp_executesql @CMD, N'@ActualMaxValue sql_variant OUTPUT', @ActualMaxValue OUTPUT;
END

SET @CMD = N'SET @LastPartitionNumber = $PARTITION.' + QUOTENAME(@PartitionFunctionName) + N'(CONVERT(' + @PartitionKeyDataType + N', @ActualMaxValue))'
EXEC sp_executesql @CMD, N'@LastPartitionNumber int OUTPUT, @ActualMaxValue sql_variant', @LastPartitionNumber OUTPUT, @ActualMaxValue

IF @TargetRangeValue IS NULL
BEGIN
	SET @MissingIntervals = CEILING((CONVERT(float, @ActualMaxValue) - CONVERT(float, @MaxPartitionRangeValue)) / CONVERT(float, @PartitionRangeInterval)) + @BufferIntervals
	SET @TargetRangeValue = CONVERT(float, @MaxPartitionRangeValue) + (CONVERT(float, @PartitionRangeInterval) * @MissingIntervals)
END

SET @Msg = CONCAT(
  N'-- @PartitionRangeInterval: ', CONVERT(nvarchar(MAX), @PartitionRangeInterval)
, N'. @MaxPartitionRangeValue: ', CONVERT(nvarchar(MAX), @MaxPartitionRangeValue)
, N'. @CurrentRangeCount: ', @CurrentRangeCount
, N'. @LastPartitionNumber: ', @LastPartitionNumber
, N'. @ActualMaxValue: ', CONVERT(nvarchar(MAX), @ActualMaxValue)
, N'. @TargetRangeValue: ', ISNULL(CONVERT(nvarchar(MAX), @TargetRangeValue), N'(null)')
, N'. @MissingIntervals: ', ISNULL(@MissingIntervals, N'(null)')
)
RAISERROR(N'%s', 0,1, @Msg) WITH NOWAIT;

IF @MissingIntervals > 0 OR CONVERT(float, @MaxPartitionRangeValue) < CONVERT(float, @TargetRangeValue)
BEGIN
	DECLARE @CurrentRangeValue sql_variant = @MaxPartitionRangeValue;

	WHILE CONVERT(float, @CurrentRangeValue) < CONVERT(float, @TargetRangeValue)
	BEGIN
		SET @CMD = N'SET @CurrentRangeValue = ' + @PartitionIncrementExpression
		EXEC sp_executesql @CMD, N'@CurrentRangeValue sql_variant OUTPUT', @CurrentRangeValue OUTPUT;
		
		SET @Msg = CONCAT(CONVERT(nvarchar(24), GETDATE(), 121), N' - Splitting range: ', CONVERT(nvarchar(max), @CurrentRangeValue))
		RAISERROR(N'%s', 0,1, @Msg) WITH NOWAIT;
		
		-- Execute NEXT USED for all dependent partition schemes
		DECLARE @CurrPS sysname, @CurrFG sysname, @NextFG sysname

		DECLARE PSFG CURSOR
		LOCAL FAST_FORWARD
		FOR
		select ps.name, dst.name
		from sys.partition_schemes AS ps
		inner join sys.partition_functions AS f ON ps.function_id = f.function_id
		cross apply
		(
			select top (1) dds.data_space_id, fg.name
			from sys.destination_data_spaces AS dds
			inner join sys.data_spaces as fg on dds.data_space_id = fg.data_space_id
			where dds.partition_scheme_id = ps.data_space_id
			order by dds.destination_id desc
		) as dst
		where f.name = @PartitionFunctionName;

		OPEN PSFG;

		WHILE 1=1
		BEGIN
			FETCH NEXT FROM PSFG INTO @CurrPS, @CurrFG;
			IF @@FETCH_STATUS <> 0 BREAK;

			SET @CMD = N'ALTER PARTITION SCHEME ' + QUOTENAME(@CurrPS) + ' NEXT USED ';

			SELECT @NextFG = FGName
			FROM @FileGroups
			WHERE FGID = (SELECT TOP (1) fg2.FGID + 1 FROM @FileGroups AS fg2 WHERE fg2.FGName = @CurrFG ORDER BY fg2.FGID)

			IF @@ROWCOUNT = 0
				SELECT @NextFG = FGName
				FROM @FileGroups
				WHERE FGID = 1;

			SET @CMD = @CMD + QUOTENAME(@NextFG);

			RAISERROR(N'%s',0,1,@CMD) WITH NOWAIT;
			IF @DebugOnly = 0 EXEC (@CMD);
		END

		CLOSE PSFG;
		DEALLOCATE PSFG;

		-- Execute SPLIT on the partition function
		SET @CMD = N'ALTER PARTITION FUNCTION ' + QUOTENAME(@PartitionFunctionName) + N'() SPLIT RANGE(CONVERT(' + @PartitionKeyDataType + N', @CurrentRangeValue)); -- ' + CONVERT(nvarchar(MAX), @CurrentRangeValue)
		RAISERROR(N'%s',0,1,@CMD) WITH NOWAIT;
		IF @DebugOnly = 0 EXEC sp_executesql @CMD, N'@CurrentRangeValue sql_variant', @CurrentRangeValue;
	
	END
END

SET @Msg = CONCAT(CONVERT(nvarchar(24), GETDATE(), 121), N' - Done.')
RAISERROR(N'%s', 0,1, @Msg) WITH NOWAIT;

END
GO