//
//  DBManager.m
//  Common
//
//  Created by 黄磊 on 16/4/6.
//  Copyright © 2016年 Musjoy. All rights reserved.
//

#import "DBManager.h"
#ifdef MODULE_UM_ANALYSE
#import "MobClick.h"
#endif

/** 最后一次数据库检查的app版本 */
#define kDBLastCheckVersion @"DBLastCheckVersion-"

static DBManager *s_dbManager = nil;

@interface DBManager ()

@property (nonatomic, strong) NSArray *arrTables;
@property (nonatomic, strong) FMDatabase  *db;

@end

@implementation DBManager

+ (DBManager *)shareInstance
{
    if (s_dbManager == nil)
    {
        s_dbManager = [[DBManager alloc] init];
    }
    return s_dbManager;
}

- (id)init
{
    self = [super init];
    if (self) {
    }
    return self;
}

- (void)openDefaultDB:(NSString *)dbName withTables:(NSArray *)arrTables
{
    if (_db) {
        [_db close];
        _db = nil;
    }
    
    NSString *fileName = [dbName stringByAppendingString:@".sqlite"];
    NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *dbPath   = [docsPath stringByAppendingPathComponent:fileName];
    _db = [FMDatabase databaseWithPath:dbPath];
    self.arrTables = arrTables;
    [_db open];
    [self createTablesWithDBName:dbName];
}

- (void)setDefalutDateFormat:(NSDateFormatter *)aDateFormatter
{
    if (aDateFormatter) {
        [DBModel setDateFormat:aDateFormatter];
    }
}

// 创建所有的表
- (void)createTablesWithDBName:(NSString *)dbName
{
    // 加入版本判断，避免频繁更新数据库
    NSString *key = [kDBLastCheckVersion stringByAppendingString:dbName];
    NSString *lastVersion = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    NSString *curVersion = kClientVersion;
    if (lastVersion && [lastVersion isEqualToString:curVersion]) {
        return;
    }
    
    for (NSString *table in self.arrTables) {
        Class tableClass = NSClassFromString(table);
        if (tableClass) {
            NSString *tableName = [tableClass tableName];
            FMResultSet *tableResult = [_db getTableSchema:tableName];
            NSArray *arrSqls = [tableClass createOrUpdateTableSqlsWith:tableResult];
            if (arrSqls.count == 0) {
                // 空的创建语句不能执行
                continue;
            }
            BOOL isSucceed = [self executeUpdates:arrSqls];
            if (!isSucceed) {
                NSString *strErr = [NSString stringWithFormat:@"数据库[%@]跟新失败", tableName];
                triggerEvent(stat_Error, @{@"name":strErr});
            }
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:curVersion forKey:key];
}

#pragma mark - Public

- (BOOL)executeUpdates:(NSArray *)arrSql
{
    if (arrSql.count == 1) {
        return [_db executeUpdate:arrSql[0]];
    }
    
    BOOL isSucceed = YES;
    [_db beginTransaction];
    for (NSString *aSql in arrSql) {
        isSucceed = [_db executeUpdate:aSql];
        if (!isSucceed) {
            break;
        }
    }
    if (isSucceed) {
        return [_db commit];
    } else {
        [_db rollback];
    }
    return isSucceed;
}

- (FMResultSet *)executeQuery:(NSString *)sql, ...
{
    return [_db executeQuery:sql];
}


#pragma mark -Model Operation

+ (BOOL)insertModel:(DBModel *)aModel
{
    // 检查是否存在改数据
    BOOL isExist = [self isExistModel:aModel];
    if (isExist) {
        // 调用update
        return [self updateModel:aModel];
    }
    NSString *strSql = [aModel insertSql];
    
    BOOL isSucceed = [[DBManager shareInstance] executeUpdates:@[strSql]];
    if (!isSucceed) {
        LogError(@"Sql Execute Faild :\n%@", strSql);
    }
    return isSucceed;
}

+ (BOOL)updateModel:(DBModel *)aModel
{
    NSString *strSql = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE (%@='%@')", [aModel.class tableName], [aModel.class primaryKey], [aModel primaryValue]];
    FMResultSet *result = [[DBManager shareInstance] executeQuery:strSql];
    if (result.next) {
        NSString *strSql1 = [aModel updateSqlFormFMResult:result];
        if (strSql1.length > 0) {
            BOOL isSucceed = [[DBManager shareInstance] executeUpdates:@[strSql1]];
            if (!isSucceed) {
                LogError(@"Sql Execute Faild :\n%@", strSql1);
            }
            return isSucceed;
        }
        // 没有需要更新的
        return YES;
    }
    
    return NO;
}

+ (BOOL)updateModelList:(NSArray *)arrModels
{
    BOOL isSucceed = YES;
    for (DBModel *aModel in arrModels) {
        BOOL result = [self updateModel:aModel];
        if (!result) {
            // 这里更新失败之后，需继续更新后面数据，处理方式需要探讨。
            LogError(@"Updata Failed!!!");
            triggerEvent(stat_Error, @{@"name":@"更新失败"});
            isSucceed = NO;
        }
    }
    return isSucceed;
}

+ (BOOL)deleteModelList:(NSArray *)arrModels
{
    NSMutableString *primaryValues = [[NSMutableString alloc] init];
    NSString *strSeparate = @"";
    for (DBModel *aModel in arrModels) {
        [primaryValues appendString:strSeparate];
        [primaryValues appendFormat:@"'%@'", [aModel primaryValue]];
        strSeparate = @",";
    }
    if (primaryValues.length > 0) {
        DBModel *aModel = arrModels[0];
        NSString *strSql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ IN (%@)", [aModel.class tableName], [aModel.class primaryKey], primaryValues];
        FMResultSet *result = [[DBManager shareInstance] executeQuery:strSql];
        return result.next;
    }
    return YES;
}

+ (BOOL)isExistModel:(DBModel *)aModel
{
    if ([aModel primaryValue] == nil) {
        return NO;
    }
    NSString *strSql = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE (%@='%@')", [aModel.class tableName], [aModel.class primaryKey], [aModel primaryValue]];
    FMResultSet *result = [[DBManager shareInstance] executeQuery:strSql];
    return result.next;
}

+ (BOOL)insertModelList:(NSArray *)arrModels
{
    BOOL isSucceed = YES;
    for (DBModel *aModel in arrModels) {
        BOOL result = [self insertModel:aModel];
        if (!result) {
            // 这里插入失败之后，需继续更新后面数据，处理方式需要探讨。
            LogError(@"Insert Failed!!!");
            triggerEvent(stat_Error, @{@"name":@"插入失败"});
            isSucceed = NO;
        }
    }
    return isSucceed;
}

+ (BOOL)forceInsertModelList:(NSArray *)arrModels
{
    if (arrModels.count == 0) {
        return YES;
    }
    NSMutableArray *arrSql = [[NSMutableArray alloc] init];
    for (DBModel *aModel in arrModels) {
        [arrSql addObject:[aModel insertSql]];
    }
    return [[DBManager shareInstance] executeUpdates:arrSql];
}

#pragma mark -Model Query

+ (__kindof DBModel *)findModel:(Class)aModelClass inCondition:(NSDictionary *)dicCondition
{
    NSMutableString *strWhereSql = [[NSMutableString alloc] init];
    NSString *strSeparate = @"";
    
    for (NSString *key in [dicCondition allKeys]) {
        [strWhereSql appendString:strSeparate];
        id value = dicCondition[key];
        [strWhereSql appendFormat:@"%@=", key];
        if ([value isKindOfClass:[NSNumber class]]) {
            [strWhereSql appendString:[value stringValue]];
        } else {
            if ([value isKindOfClass:[NSString class]]) {
                value = [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
            }
            [strWhereSql appendFormat:@"'%@'", value];
        }
        strSeparate = @" AND ";
    }
    return [self findModel:aModelClass withWhereSql:strWhereSql];
}

+ (DBModel *)findModel:(Class)aModelClass withWhereSql:(NSString *)strWhereSql
{
    NSMutableString *strSql = [[NSMutableString alloc] init];
    [strSql appendFormat:@"SELECT * FROM %@ WHERE (%@) LIMIT 1", [aModelClass tableName], strWhereSql];
    FMResultSet *result = [[self shareInstance] executeQuery:strSql];
    if (result.next) {
        return [aModelClass modelWithFMResult:result];
    }
    return nil;
}

+ (NSArray *)findModelList:(Class)aModelClass inCondition:(NSDictionary *)dicCondition
{
    return [self findModelList:aModelClass inCondition:dicCondition orderBy:nil];
}

+ (NSArray *)findModelList:(Class)aModelClass inCondition:(NSDictionary *)dicCondition orderBy:(NSString *)orderBy
{
    NSMutableString *strWhereSql = [[NSMutableString alloc] init];
    NSString *strSeparate = @"";
    
    for (NSString *key in [dicCondition allKeys]) {
        [strWhereSql appendString:strSeparate];
        id value = dicCondition[key];
        [strWhereSql appendFormat:@"%@=", key];
        if ([value isKindOfClass:[NSNumber class]]) {
            [strWhereSql appendString:[value stringValue]];
        } else {
            if ([value isKindOfClass:[NSString class]]) {
                value = [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
            }
            [strWhereSql appendFormat:@"'%@'", value];
        }
        strSeparate = @" AND ";
    }
    return [self findModelList:aModelClass withWhereSql:strWhereSql orderBy:orderBy];
}

+ (NSArray *)findModelList:(Class)aModelClass withWhereSql:(NSString *)strWhereSql
{
    return [self findModelList:aModelClass withWhereSql:strWhereSql orderBy:nil];
}

+ (NSArray *)findModelList:(Class)aModelClass withWhereSql:(NSString *)strWhereSql orderBy:(NSString *)orderBy
{
    NSMutableString *strSql = [[NSMutableString alloc] init];
    [strSql appendFormat:@"SELECT * FROM %@", [aModelClass tableName]];
    if (strWhereSql.length > 0) {
        [strSql appendFormat:@" WHERE (%@)",strWhereSql];
    }
    if (orderBy.length > 0) {
        if ([self isString:orderBy containString:@"ORDER BY"]) {
            [strSql appendFormat:@" %@", orderBy];
        } else {
            [strSql appendFormat:@" ORDER BY %@", orderBy];
        }
    }
    FMResultSet *result = [[self shareInstance] executeQuery:strSql];
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    while (result.next) {
        DBModel *aModel = [aModelClass modelWithFMResult:result];
        [arr addObject:aModel];
    }
    return arr;
}

+ (NSArray *)findModelList:(Class)aModelClass join:(NSString *)strJoin withWhereSql:(NSString *)strWhereSql orderBy:(NSString *)orderBy
{
    NSMutableString *strSql = [[NSMutableString alloc] init];
    [strSql appendFormat:@"SELECT * FROM %@ %@", [aModelClass tableName], strJoin];
    if (strWhereSql.length > 0) {
        [strSql appendFormat:@" WHERE (%@)",strWhereSql];
    }
    if (orderBy.length > 0) {
        if ([self isString:orderBy containString:@"ORDER BY"]) {
            [strSql appendFormat:@" %@", orderBy];
        } else {
            [strSql appendFormat:@" ORDER BY %@", orderBy];
        }
    }
    FMResultSet *result = [[self shareInstance] executeQuery:strSql];
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    while (result.next) {
        DBModel *aModel = [aModelClass modelWithFMResult:result];
        [arr addObject:aModel];
    }
    return arr;
}



+ (int)countFromModel:(Class)aModelClass inCondition:(NSDictionary *)dicCondition
{
    NSMutableString *strWhereSql = [[NSMutableString alloc] init];
    NSString *strSeparate = @"";
    
    for (NSString *key in [dicCondition allKeys]) {
        [strWhereSql appendString:strSeparate];
        id value = dicCondition[key];
        [strWhereSql appendFormat:@"%@=", key];
        if ([value isKindOfClass:[NSNumber class]]) {
            [strWhereSql appendString:[value stringValue]];
        } else {
            [strWhereSql appendFormat:@"'%@'", value];
        }
        strSeparate = @" AND ";
    }
    return [self countFromModel:aModelClass withWhereSql:strWhereSql];
}

+ (int)countFromModel:(Class)aModelClass withWhereSql:(NSString *)strWhereSql
{
    NSMutableString *strSql = [[NSMutableString alloc] init];
    [strSql appendFormat:@"SELECT count(*) FROM %@ WHERE (%@)", [aModelClass tableName], strWhereSql];
    FMResultSet *result = [[self shareInstance] executeQuery:strSql];
    if (result.next) {
        return [result intForColumnIndex:0];
    }
    return 0;
}


#pragma mark - Other DB


+ (BOOL)theDB:(FMDatabase *)db executeUpdates:(NSArray *)arrSql
{
    if (arrSql.count == 1) {
        return [db executeUpdate:arrSql[0]];
    }
    
    BOOL isSucceed = YES;
    [db beginTransaction];
    for (NSString *aSql in arrSql) {
        isSucceed = [db executeUpdate:aSql];
        if (!isSucceed) {
            break;
        }
    }
    if (isSucceed) {
        return [db commit];
    } else {
        [db rollback];
    }
    return isSucceed;
}

+ (FMResultSet *)theDB:(FMDatabase *)db executeQuery:(NSString *)sql, ...
{
    return [db executeQuery:sql];
}


#pragma mark -Model Operation

+ (BOOL)theDB:(FMDatabase *)db insertModel:(DBModel *)aModel
{
    // 检查是否存在改数据
    BOOL isExist = [self theDB:db isExistModel:aModel];
    if (isExist) {
        // 调用update
        return [self theDB:db updateModel:aModel];
    }
    NSString *strSql = [aModel insertSql];
    
    BOOL isSucceed = [self theDB:db executeUpdates:@[strSql]];
    if (!isSucceed) {
        LogError(@"Sql Execute Faild :\n%@", strSql);
    }
    return isSucceed;
}

+ (BOOL)theDB:(FMDatabase *)db updateModel:(DBModel *)aModel
{
    NSString *strSql = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE (%@='%@')", [aModel.class tableName], [aModel.class primaryKey], [aModel primaryValue]];
    FMResultSet *result = [self theDB:db executeQuery:strSql];
    if (result.next) {
        NSString *strSql1 = [aModel updateSqlFormFMResult:result];
        if (strSql1.length > 0) {
            BOOL isSucceed = [self theDB:db executeUpdates:@[strSql1]];
            if (!isSucceed) {
                LogError(@"Sql Execute Faild :\n%@", strSql1);
            }
            return isSucceed;
        }
    }
    
    return NO;
}

+ (BOOL)theDB:(FMDatabase *)db updateModelList:(NSArray *)arrModels
{
    for (DBModel *aModel in arrModels) {
        BOOL result = [self theDB:db updateModel:aModel];
        if (!result) {
            return result;
        }
    }
    return YES;
}

+ (BOOL)theDB:(FMDatabase *)db deleteModelList:(NSArray *)arrModels
{
    NSMutableString *primaryValues = [[NSMutableString alloc] init];
    NSString *strSeparate = @"";
    for (DBModel *aModel in arrModels) {
        [primaryValues appendString:strSeparate];
        [primaryValues appendFormat:@"'%@'", [aModel primaryValue]];
        strSeparate = @",";
    }
    if (primaryValues.length > 0) {
        DBModel *aModel = arrModels[0];
        NSString *strSql = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ IN (%@)", [aModel.class tableName], [aModel.class primaryKey], primaryValues];
        FMResultSet *result = [self theDB:db executeQuery:strSql];
        return result.next;
    }
    return YES;
}

+ (BOOL)theDB:(FMDatabase *)db isExistModel:(DBModel *)aModel
{
    if ([aModel primaryValue] == nil) {
        return NO;
    }
    NSString *strSql = [NSString stringWithFormat:@"SELECT * FROM %@ WHERE (%@='%@')", [aModel.class tableName], [aModel.class primaryKey], [aModel primaryValue]];
    FMResultSet *result = [self theDB:db executeQuery:strSql];
    return result.next;
}

+ (BOOL)theDB:(FMDatabase *)db insertModelList:(NSArray *)arrModels
{
    for (DBModel *aModel in arrModels) {
        BOOL result = [self theDB:db insertModel:aModel];
        if (!result) {
            return result;
        }
    }
    return YES;
}

+ (BOOL)theDB:(FMDatabase *)db forceInsertModelList:(NSArray *)arrModels
{
    if (arrModels.count == 0) {
        return YES;
    }
    NSMutableArray *arrSql = [[NSMutableArray alloc] init];
    for (DBModel *aModel in arrModels) {
        [arrSql addObject:[aModel insertSql]];
    }
    return [self theDB:db executeUpdates:arrSql];
}

#pragma mark -Model Query

+ (DBModel *)theDB:(FMDatabase *)db findModel:(Class)aModelClass withWhereSql:(NSString *)strWhereSql
{
    NSMutableString *strSql = [[NSMutableString alloc] init];
    [strSql appendFormat:@"SELECT * FROM %@ WHERE (%@) LIMIT 1", [aModelClass tableName], strWhereSql];
    FMResultSet *result = [self theDB:db executeQuery:strSql];
    if (result.next) {
        return [aModelClass modelWithFMResult:result];
    }
    return nil;
}

+ (NSArray *)theDB:(FMDatabase *)db findModelList:(Class)aModelClass withWhereSql:(NSString *)strWhereSql orderBy:(NSString *)orderBy
{
    NSMutableString *strSql = [[NSMutableString alloc] init];
    [strSql appendFormat:@"SELECT * FROM %@", [aModelClass tableName]];
    if (strWhereSql.length > 0) {
        [strSql appendFormat:@" WHERE (%@)",strWhereSql];
    }
    if (orderBy.length > 0) {
        if ([self isString:orderBy containString:@"ORDER BY"]) {
            [strSql appendFormat:@" %@", orderBy];
        } else {
            [strSql appendFormat:@" ORDER BY %@", orderBy];
        }
    }
    FMResultSet *result = [self theDB:db executeQuery:strSql];
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    while (result.next) {
        DBModel *aModel = [aModelClass modelWithFMResult:result];
        [arr addObject:aModel];
    }
    return arr;
}

+ (NSArray *)theDB:(FMDatabase *)db findModelList:(Class)aModelClass join:(NSString *)strJoin withWhereSql:(NSString *)strWhereSql orderBy:(NSString *)orderBy
{
    NSMutableString *strSql = [[NSMutableString alloc] init];
    [strSql appendFormat:@"SELECT * FROM %@ %@", [aModelClass tableName], strJoin];
    if (strWhereSql.length > 0) {
        [strSql appendFormat:@" WHERE (%@)",strWhereSql];
    }
    if (orderBy.length > 0) {
        if ([self isString:orderBy containString:@"ORDER BY"]) {
            [strSql appendFormat:@" %@", orderBy];
        } else {
            [strSql appendFormat:@" ORDER BY %@", orderBy];
        }
    }
    FMResultSet *result = [self theDB:db executeQuery:strSql];
    NSMutableArray *arr = [[NSMutableArray alloc] init];
    while (result.next) {
        DBModel *aModel = [aModelClass modelWithFMResult:result];
        [arr addObject:aModel];
    }
    return arr;
}


#pragma mark - Support

+ (BOOL)isString:(NSString *)aStr containString:(NSString *)strContain
{
    if (strContain == nil) {
        return NO;
    }
#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_8_0
    return [aStr containsString:strContain];
#else
    NSRange aRange = [aStr rangeOfString:strContain];
    if (aRange.length > 0) {
        return YES;
    }
    return NO;
#endif
}


#pragma mark - 数据库升级

- (void)checkDBUpdate
{

}

@end