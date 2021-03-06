//
//  ActiveRecord.m
//  iActiveRecord
//
//  Created by Alex Denisov on 10.01.12.
//  Copyright (c) 2012 okolodev.org. All rights reserved.
//

#import "ActiveRecord.h"
#import "ARDatabaseManager.h"
#import "NSString+lowercaseFirst.h"
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import "ARValidationsHelper.h"
#import "ARErrorHelper.h"
#import "ARDatabaseManager.h"

#import "ARRelationBelongsTo.h"
#import "ARRelationHasMany.h"
#import "ARRelationHasManyThrough.h"

#import "ARValidator.h"
#import "ARValidatorUniqueness.h"
#import "ARValidatorPresence.h"
#import "ARException.h"
#import "NSString+stringWithEscapedQuote.h"
#import "NSMutableDictionary+valueToArray.h"

#import "ActiveRecord_Private.h"
#import "ARSchemaManager.h"
#import "ARColumn.h"

#import "ARDynamicAccessor.h"
#import "ARConfiguration.h"
#import "ARPersistentQueueEntity.h"
#import "ARSynchronizationProtocol.h"
#import "NSString+sqlRepresentation.h"

static NSMutableDictionary *relationshipsDictionary = nil;
static NSMutableDictionary *recordTableName = nil;

@implementation ActiveRecord
@dynamic id;
@dynamic createdAt;
@dynamic updatedAt;

#pragma mark - Initialize

+ (void)initialize {
    [super initialize];
    [self initializeMapping];
    [self initializeIndices];
    [[ARSchemaManager sharedInstance] registerSchemeForRecord:self];
    [self initializeValidators];
    [self initializeDynamicAccessors];
    [self registerRelationships];
}

+ (instancetype) record {
    return [self new: nil];
}

+ (instancetype) record: (NSDictionary *) values {
    return [self new: values];
}

+ (instancetype) new {
    return [self new: nil];
}

+ (instancetype) new: (NSDictionary *) values {
    ActiveRecord *newRow = [[self alloc] init];
    [newRow markAsNew];

    if(values) for(id key in values) {
         //   ARColumn *column =  [self columnWithGetterNamed:key];
            NSString *baseName = [key stringByReplacingCharactersInRange:NSMakeRange(0,1)
                                                              withString:[[key substringToIndex:1] uppercaseString]];
            SEL setterMethod = NSSelectorFromString([NSString stringWithFormat:@"set%@:",baseName]);
            id columnValue = [values objectForKey:key];

            NSAssert([newRow respondsToSelector:setterMethod],
                     @"'%@' is not an existing column for %@ class.",key,  NSStringFromClass([newRow class]));

           //  [newRow performSelector:setterMethod withObject: columnValue ];
        ((void (*)(id, SEL,id))[newRow methodForSelector:setterMethod])(newRow, setterMethod,columnValue);
    }
    return newRow;
}

+ (instancetype) create: (NSDictionary *) values {
    ActiveRecord *newRow = [self new: values];
    if([newRow save])
        return newRow;
    return nil;
}

#pragma mark - registering relationships

static NSMutableSet *belongsToRelations = nil;
static NSMutableSet *hasManyRelations = nil;
static NSMutableSet *hasManyThroughRelations = nil;

static NSString *registerBelongs = @"_ar_registerBelongsTo";
static NSString *registerHasMany = @"_ar_registerHasMany";
static NSString *registerHasManyThrough = @"_ar_registerHasManyThrough";

+ (void)registerRelationships {
    if (relationshipsDictionary == nil) {
        relationshipsDictionary = [NSMutableDictionary new];
    }
    uint count = 0;
    Method *methods = class_copyMethodList(object_getClass(self), &count);
    for (int i = 0; i < count; i++) {
        NSString *selectorName = NSStringFromSelector(method_getName(methods[i]));
        if ([selectorName hasPrefix:registerBelongs]) {
            [self registerBelongs:selectorName];
            continue;
        }
        if ([selectorName hasPrefix:registerHasManyThrough]) {
            [self registerHasManyThrough:selectorName];
            continue;
        }
        if ([selectorName hasPrefix:registerHasMany]) {
            [self registerHasMany:selectorName];
            continue;
        }
    }
    free(methods);
}

+ (void)registerBelongs:(NSString *)aSelectorName {
    if (belongsToRelations == nil) {
        belongsToRelations = [NSMutableSet new];
    }
    SEL selector = NSSelectorFromString(aSelectorName);
    NSString *relationName = [aSelectorName stringByReplacingOccurrencesOfString:registerBelongs
                                                                      withString:@""];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    ARDependency dependency = (ARDependency)[self performSelector:selector];
#pragma clang diagnostic pop
    ARRelationBelongsTo *relation = [[ARRelationBelongsTo alloc] initWithRecord:[self className]
                                                                       relation:relationName
                                                                      dependent:dependency];
    [relationshipsDictionary addValue:relation
                         toArrayNamed:[self className]];
}

+ (void)registerHasMany:(NSString *)aSelectorName {
    if (hasManyRelations == nil) {
        hasManyRelations = [NSMutableSet new];
    }
    SEL selector = NSSelectorFromString(aSelectorName);
    NSString *relationName = [aSelectorName stringByReplacingOccurrencesOfString:registerHasMany
                                                                      withString:@""];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    ARDependency dependency = (ARDependency)[self performSelector:selector];
#pragma clang diagnostic pop
    ARRelationHasMany *relation = [[ARRelationHasMany alloc] initWithRecord:[self className]
                                                                   relation:relationName
                                                                  dependent:dependency];
    [relationshipsDictionary addValue:relation
                         toArrayNamed:[self className]];
}

+ (void)registerHasManyThrough:(NSString *)aSelectorName {
    if (hasManyThroughRelations == nil) {
        hasManyThroughRelations = [NSMutableSet new];
    }
    SEL selector = NSSelectorFromString(aSelectorName);
    NSString *records = [aSelectorName stringByReplacingOccurrencesOfString:registerHasManyThrough
                                                                 withString:@""];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    ARDependency dependency = (ARDependency)[self performSelector:selector];
#pragma clang diagnostic pop
    NSArray *components = [records componentsSeparatedByString:@"_ar_"];
    NSString *relationName = [components objectAtIndex:0];
    NSString *throughRelationname = [components objectAtIndex:1];
    ARRelationHasManyThrough *relation = [[ARRelationHasManyThrough alloc] initWithRecord:[self className]
                                                                            throughRecord:throughRelationname
                                                                                 relation:relationName
                                                                                dependent:dependency];
    [relationshipsDictionary addValue:relation
                         toArrayNamed:[self className]];
}

#pragma mark - private before filter

- (void)privateAfterDestroy {
    for (ARBaseRelationship *relation in [self relationships]) {
        
        if (relation.dependency != ARDependencyDestroy) {
            continue;
        }
        
        switch ([relation type]) {
            case ARRelationTypeBelongsTo:
            {
                [[self belongsTo:relation.relation] dropRecord];
            } break;
            case ARRelationTypeHasManyThrough:
            {
                [[[self hasMany:relation.relation
                        through:relation.throughRecord] fetchRecords]
                 makeObjectsPerformSelector:@selector(dropRecord)];
            } break;
            case ARRelationTypeHasMany:
            {
                [[[self hasManyRecords:relation.relation]
                  fetchRecords]
                 makeObjectsPerformSelector:@selector(dropRecord)];
            } break;
            default:
                break;
        }
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
     //   self.createdAt = self.updatedAt = [NSDate dateWithTimeIntervalSinceNow:0];
        self.entityCache = [NSMutableDictionary dictionary];
        self.changedColumns = [NSMutableSet setWithCapacity: 1];
        self.deserializedCache = [NSMutableDictionary dictionary];
        shouldSync = NO;
    }
    return self;
}

- (void)dealloc {
    for (ARColumn *column in self.columns) {
        objc_setAssociatedObject(self, column.columnKey,
                                 nil, OBJC_ASSOCIATION_ASSIGN);
    }

    self.id = nil;
    self.updatedAt = nil;
    self.createdAt = nil;
    self.entityCache = nil;
    self.deserializedCache = nil;
}

- (void)markAsNew {
    isNew = YES;
}
- (void)markAsPersisted {
    isNew = NO;
}
#pragma mark -
- (BOOL) isDirty {
    return  [self.changedColumns count]>0 || [self hasQueuedRelationships];
}

- (void)resetChanges {
    [self.changedColumns removeAllObjects];
}

- (void)resetErrors {
    errors = nil;
}

- (void)addErrors:(NSArray*) errorz {
    for(ARError *error in errorz)
        [self addError:error];
}

- (void)addError:(ARError *)anError {
    if (nil == errors) {
        errors = [NSMutableSet setWithCapacity: 1];
    }
    [errors addObject:anError];
}

#pragma mark -

+ (NSArray *)relationships {
    return [relationshipsDictionary objectForKey:[self className]];
}

- (NSArray *)relationships {
    return [[self class] relationships];
}

+ (NSMutableDictionary *)tableNameDictionary { //to be used by recordName & tableName dictionary always has value
    if (recordTableName == nil) {
        recordTableName = [NSMutableDictionary new];
    }
    return recordTableName;
}

+ (NSString *)className { //TODO: Rename this, its to be used as the Key for any given model.
    NSString *name = NSStringFromClass([self class]);
    NSArray *components = [name componentsSeparatedByString:@"."];
    // Swift returns Package.ClassName and we only want ClassName
    if(components)
        return [components lastObject];
    return name;
}

+ (NSString *)recordName {
    //TODO: Needs to be refactored, but basically to maintain compat with iActiveRecord, you should be able to ALSO
    //      just override this method for a table. Wherefore, however mapping takes precedence.
    NSString *tableName = [self tableNameDictionary][[self className]];
    if(tableName)
        return tableName;

    return [self className];
}

- (NSString *)recordName {
    return [[self class] recordName];
}

- (NSString*) foreignPropertyKey {
    //[NSString stringWithFormat:@"%@Id", [[row recordName] lowercaseFirst]];
    return [self.class foreignPropertyKey];
}
+ (NSString*) foreignPropertyKey {
    //[NSString stringWithFormat:@"%@Id", [[row recordName] lowercaseFirst]];
    return [NSString stringWithFormat:@"%@Id",[[self className] lowercaseFirst] ];
}

+ (void)setTableName:(NSString*) tableName {
    NSMutableDictionary *dictionary = [self tableNameDictionary];
    dictionary[[self className]] = tableName;
}

+ (NSString *) tableName {
    NSString *tableName = recordTableName[[self className]];
    return tableName ? tableName : [self recordName];
}

- (NSString *) tableName {
    return [[self class] tableName];
}

+ (instancetype)persistedRecord {
    ActiveRecord *record = [self new:nil];
    [record markAsPersisted];
    return record;
}
+ (instancetype)newRecord {
    return [self new: nil];
   }

- (instancetype)reload {
    [self.entityCache removeAllObjects];

    if([self isNewRecord])
        return self;

    ActiveRecord *existingRecord = [[[[[self class] lazyFetcher] where:@"id == %@", self.id, nil] fetchRecords] firstObject];

    if(existingRecord)
        [self copyFrom:existingRecord merge:NO];

    return self;
}


#pragma mark - Fetchers
+ (NSArray *) all {
    ARLazyFetcher *fetcher = [[ARLazyFetcher alloc] initWithRecord:[self class]];
    return [fetcher fetchRecords];
}
+ (NSArray *)allRecords {
    return [self all];
}

+ (ARLazyFetcher *)lazyFetcher {
    ARLazyFetcher *fetcher = [[ARLazyFetcher alloc] initWithRecord:[self class]];
    return fetcher;
}

#pragma mark - cache

- (ActiveRecord*) setCachedEntity: (ActiveRecord *) entity forKey: (NSString *) field {
    [self.entityCache setValue:entity forKey:field];
    return entity;
}

- (ActiveRecord *) cachedEntityForKey: (NSString *) field {
    return (ActiveRecord*)[self.entityCache objectForKey:field];
}

- (NSArray*) cachedArrayForKey: (NSString *) field {
    return (NSArray*) [self.entityCache objectForKey:field];
}

- (void) addCachedEntity: (ActiveRecord *) entity forKey: (NSString *) field {
    NSString *fieldKey = field;
    NSMutableArray *entityArray = (NSMutableArray*)[self.entityCache objectForKey:fieldKey];

    if(!entityArray) {
        entityArray = [NSMutableArray arrayWithCapacity:1];
        [self.entityCache setObject:entityArray forKey:fieldKey];
    }

    [entityArray addObject:entity];
}


- (void) removeCachedEntity: (ActiveRecord *) entity forKey: (NSString *) field {
        NSString *fieldKey = field;
        NSMutableArray *entityArray = [self.entityCache objectForKey:fieldKey];
        [entityArray removeObject :entity];
}


#pragma mark - Validations

+ (void)initializeValidators {
    //  nothing goes there
}


+ (void)validateUniquenessOfField:(NSString *)aField {
    [ARValidator registerValidator:[ARValidatorUniqueness class]
                         forRecord:[self className]
                           onField:aField];
}

+ (void)validatePresenceOfField:(NSString *)aField {
    [ARValidator registerValidator:[ARValidatorPresence class]
                         forRecord:[self className]
                           onField:aField];
}

+ (void)validateField:(NSString *)aField withValidator:(NSString *)aValidator {
    [ARValidator registerValidator:NSClassFromString(aValidator)
                         forRecord:[self className]
                           onField:aField];
}

- (BOOL)isValid {
    BOOL valid = YES;
    [self resetErrors];
    if (isNew) {
        valid = [ARValidator isValidOnSave:self];
    }else {
        valid = [ARValidator isValidOnUpdate:self];
    }
    return valid;
}

- (NSArray *)errors {
    return [errors allObjects];
}

#pragma mark - AR Callbacks

+ (void)initializeCallbacks {
        // nothing goes here
}


- (void) beforeSave {}

- (void) afterSave {}

- (void) beforeUpdate {}

- (void) afterUpdate{}

- (void) beforeValidation {}

- (void) afterValidation {}

- (void) beforeCreate {}

- (void) afterCreate {}

- (void) beforeDestroy {}

- (void) afterDestroy {}

- (void) beforeSync {}

- (void) afterSync {}



#pragma mark - Save/Update/Sync

- (void) markForSychronization {
    shouldSync = YES;
}

- (BOOL) syncScheduled {
    return shouldSync;
}

- (void) markQueuedRelationshipsForSynchronization {

    if([self syncScheduled]) return;
    [self markForSychronization];
    /*   //DEPRICATED because entityCache has all entities before save.
    for(ARPersistentQueueEntity* entity in self.belongsToPersistentQueue) {
            [entity.record markQueuedRelationshipsForSynchronization];
    }
    for(ARPersistentQueueEntity* entity in self.hasManyPersistentQueue) {
            [entity.record markQueuedRelationshipsForSynchronization];
    }
    for(ARPersistentQueueEntity* entity in self.hasManyThroughRelationsQueue) {
            [entity.record markQueuedRelationshipsForSynchronization];
    } */

    for(id value in [self.entityCache allValues]) {
        if([value isKindOfClass:[ActiveRecord class]])   {
            ActiveRecord * record = (ActiveRecord *)value;
            [record markQueuedRelationshipsForSynchronization];
        } else if([value isKindOfClass:[NSArray class]]) {
            for(ActiveRecord *record in value)
                [record markQueuedRelationshipsForSynchronization];
        }
    }
}


- (BOOL) hasQueuedRelationships {
    NSInteger belongsToCount = [self.belongsToPersistentQueue count];
    NSInteger hasManyCount = [self.hasManyPersistentQueue count];
    NSInteger hasManyThroughCount = [self.hasManyThroughRelationsQueue count];

    return (belongsToCount+hasManyCount+hasManyThroughCount) > 0;
}

- (BOOL) persistQueuedBelongsToRelationships {
    BOOL success = YES;

    for(ARPersistentQueueEntity* entity in self.belongsToPersistentQueue) {
        if(![self persistRecord:entity.record belongsTo:entity.relation]) {
            for(ARError *error in entity.record.errors) {
                [self addError:error];
                success = NO;
            }
        }
    }

    if(success) {
        [self.belongsToPersistentQueue removeAllObjects];
    }

    return success;
}

- (BOOL) persistQueuedManyRelationships {
    BOOL success = YES;

    for(ARPersistentQueueEntity* entity in self.hasManyPersistentQueue) {
        if(![self persistRecord:entity.record]) {
            for(ARError *error in entity.record.errors) {
                [self addError:error];
                success = NO;
            }
        }
    }

    for(ARPersistentQueueEntity* entity in self.hasManyThroughRelationsQueue) {
        if(![self persistRecord:entity.record ofClass:entity.className through:entity.relationshipClass]) {
            for(ARError *error in entity.record.errors) {
                [self addError:error];
                success = NO;
            }
        }
    }

    if(success) {
        [self.hasManyThroughRelationsQueue removeAllObjects];
        [self.hasManyPersistentQueue removeAllObjects];
    }

    return success;
}


    - (void) copyFrom: (ActiveRecord *) copy  {
        [self copyFrom:copy  merge:NO];
    }

- (void) copyFrom: (ActiveRecord *) copy merge: (BOOL) merge{

    if(![copy isKindOfClass:[self class]])  return;

    NSSet *columnSet = [NSSet setWithSet: self.changedColumns];

    for(ARColumn *col in [copy columns]) {
        if(merge && [columnSet containsObject:col])
            continue;

        id value = [copy valueForColumn:col];
        [self setValue:value forColumn:col];
    }
}

- (BOOL)save {
    BOOL wasNew = isNew;

    if (!isNew) {
        return [self update];
    } else if(shouldSync) {
        if ([self conformsToProtocol:@protocol(ARSynchronizationProtocol)] ) {
            ActiveRecord <ARSynchronizationProtocol> *wself = self;
            ActiveRecord *existingRecord = nil;

            if([wself respondsToSelector:@selector(mergeExistingRecord)] &&
                    (existingRecord = [wself mergeExistingRecord]) && existingRecord.id)  {
                self.id = existingRecord.id;
                [self copyFrom:existingRecord merge: YES];
                isNew = shouldSync = NO;
                return [self update];
            } else if([wself respondsToSelector:@selector(overwriteExistingRecord)]
                    && (existingRecord = [wself overwriteExistingRecord]) && existingRecord.id)  {
                self.id = existingRecord.id;
                isNew = shouldSync = NO;
                return [self update];
            }
        }

        shouldSync = NO;
    }

    /* If queued belongs_to relationship exists, we should have those before saving ourselves
    *  because validations could rely on the existence of such properties. */



    if(![self persistQueuedBelongsToRelationships]) {
        return NO;
    }

    [self beforeValidation];
    if (![self isValid]) {
        return NO;
    }
    [self afterValidation];

    [self beforeSave];
    if(wasNew)
        [self beforeCreate];
    NSInteger newRecordId = [[ARDatabaseManager sharedManager] saveRecord:self];
    if (newRecordId) {
        self.id = [NSNumber numberWithInteger:newRecordId];
        isNew = NO;
        [self resetChanges];
        /* Saved queued relationships (hasMany/hasManyThrough) which all depend on id of this model.
        * If any models fail to persist, their validation errors are added to this objects errors array. */
        BOOL success =  [self persistQueuedManyRelationships];
        if(success){

            [self.entityCache removeAllObjects];
            if(wasNew)
                [self afterCreate];
            [self afterSave];
        }

        return success;
    }
    return NO;
}

- (BOOL) sync {
    BOOL success = NO;
    [self beforeSync];
    [self markQueuedRelationshipsForSynchronization];

    success = [self save];

    if(success)
        [self afterSync];

    return success;
}

- (BOOL)update {
    if (isNew) {
        return [self save];
    }

    if(![self persistQueuedBelongsToRelationships]) {
        return NO;
    }

    [self beforeValidation];
    if (![self isValid]) {
        return NO;
    }
    [self afterValidation];

    [self beforeSave];
    [self beforeUpdate];
    NSInteger result = [[ARDatabaseManager sharedManager] updateRecord:self];
    if (result) {
        [self resetChanges];
        BOOL success = [self persistQueuedManyRelationships];
        if(success) {

            [self.entityCache removeAllObjects];
            [self afterUpdate];
            [self afterSave];
        }
        return success;
       // return YES;
    }
    return NO;
}

+ (NSInteger)count {
    return [[ARDatabaseManager sharedManager] countOfRecordsWithName: [self tableName]];
}

#pragma mark - Relationships

#pragma mark BelongsTo

- (id)belongsTo:(NSString *)aClassName {
    Class <ActiveRecord> aClass = NSClassFromString(aClassName);
    NSString *selectorString = [aClass performSelector:@selector(foreignPropertyKey)] ;//[NSString stringWithFormat:@"%@Id", [aClassName lowercaseFirst]];
    SEL selector = NSSelectorFromString(selectorString);
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    NSNumber *rec_id = [self performSelector:selector];
#pragma clang diagnostic pop
    ActiveRecord *cachedEntity = [self cachedEntityForKey:selectorString];

    if(cachedEntity)
        return cachedEntity;
    else if (rec_id == nil) {
        return nil;
    }


    ARLazyFetcher *fetcher = [[ARLazyFetcher alloc] initWithRecord:NSClassFromString(aClassName)];
    [fetcher where:@"id = %@", rec_id, nil];
    NSArray *records = [fetcher fetchRecords];
    return records.count ? [self setCachedEntity:[records objectAtIndex:0] forKey:selectorString] : nil;
}


- (void)setRecord:(ActiveRecord *)aRecord belongsTo:(NSString *)aRelation {
    Class <ActiveRecord> aClass = NSClassFromString(aRelation);
    NSString *selectorString = [aClass performSelector:@selector(foreignPropertyKey)] ;//[NSString stringWithFormat:@"%@Id", [aRelation lowercaseFirst]];

    [self setCachedEntity:aRecord forKey:selectorString];

    if(![aRecord isNewRecord] && ![self isNewRecord] &&
            [self persistRecord: aRecord belongsTo:aRelation]) {
        [self update];
        return;
    }

    ARPersistentQueueEntity *entity = [ARPersistentQueueEntity entityBelongingToRecord:aRecord relation:aRelation];
    if(!self.belongsToPersistentQueue ) {
        self.belongsToPersistentQueue = [NSMutableSet setWithCapacity: 1];
    }

    [self.belongsToPersistentQueue  removeObject:entity];
    [self.belongsToPersistentQueue  addObject:entity];
}

- (BOOL)persistRecord:(ActiveRecord *)aRecord belongsTo:(NSString *)aRelation {
    NSString *relId = [NSString stringWithFormat:
            @"%@Id", [aRelation lowercaseFirst]];
    ARColumn *column = [self columnNamed:relId];
    BOOL success  = YES;

    if([aRecord isNewRecord])
        success = [aRecord save];


    [self setValue:aRecord.id
         forColumn:column];
    return success;
}
#pragma mark HasMany
- (BOOL) isNewRecord {
    return !self.id && isNew;
}

- (void)addRecord:(ActiveRecord *)aRecord {
    NSString *entityKey = [aRecord foreignPropertyKey];
    [self addCachedEntity:aRecord forKey:entityKey];

    if(![aRecord isNewRecord] &&  [self persistRecord:aRecord])
        return;

    if(!self.hasManyPersistentQueue) {
       self.hasManyPersistentQueue = [NSMutableSet setWithCapacity: 1];
    }

    [self.hasManyPersistentQueue addObject: [ARPersistentQueueEntity entityHavingManyRecord:aRecord]];
}

- (BOOL)persistRecord:(ActiveRecord *)aRecord {
    NSString *relationIdKey = [self foreignPropertyKey];
    ARColumn *column = [aRecord columnNamed:relationIdKey];
    [aRecord setValue:self.id forColumn:column];
    return [aRecord save];
}

- (void)removeRecord:(ActiveRecord *)aRecord {
    NSString *entityKey = [aRecord foreignPropertyKey]; //[NSString stringWithFormat:@"%@", [[aRecord recordName] lowercaseFirst]];
    NSString *relationIdKey = [self foreignPropertyKey]; // [NSString stringWithFormat:@"%@Id", [[self recordName] lowercaseFirst]];
    ARColumn *column = [aRecord columnNamed:relationIdKey];

    [self removeCachedEntity:aRecord forKey:entityKey];
    //[aRecord removeCachedEntity:self forKey:relationIdKey];//;[[self recordName] lowercaseFirst]
    [aRecord setCachedEntity:nil forKey:relationIdKey];

    [aRecord setValue:nil forColumn:column];
    [aRecord save];
}

- (ARLazyFetcher *)hasManyRecords:(NSString *)aClassName {
    //ARLazyFetcher *fetcher = [[ARLazyFetcher alloc] initWithRecord:NSClassFromString(aClassName)];
    //NSString *selfId = [NSString stringWithFormat:@"%@Id", [[self class] description]];
    //[fetcher where:@"%@ = %@", selfId, self.id, nil];

    ARLazyFetcher *fetcher = [[ARLazyFetcher  alloc] initWithRecord:self thatHasMany:aClassName through:nil];
    return fetcher;
}

#pragma mark HasManyThrough

- (ARLazyFetcher *)hasMany:(NSString *)aClassName through:(NSString *)aRelationsipClassName {
    //NSString *relId = [NSString stringWithFormat:@"%@Id", [[self recordName] lowercaseFirst]];
    //ARLazyFetcher *fetcher = [[ARLazyFetcher alloc] initWithRecord:NSClassFromString(aClassName)];
    //Class relClass = NSClassFromString(aRelationsipClassName);

    ARLazyFetcher *fetcher = [[ARLazyFetcher  alloc] initWithRecord:self thatHasMany:aClassName through:aRelationsipClassName];


    //[fetcher join: relClass];
    //[fetcher where:@"%@.%@ = %@", [relClass performSelector: @selector(recordName)], relId, self.id, nil];
    return fetcher;
}


- (void)addRecord:(ActiveRecord *)aRecord
          ofClass:(NSString *)aClassname
          through:(NSString *)aRelationshipClassName
{
    Class <ActiveRecord > aClass = NSClassFromString(aClassname);

    NSString *entityKey =  [aClass performSelector:@selector(foreignPropertyKey)];// [NSString stringWithFormat:@"%@", [ [aClass className] lowercaseFirst]];
    [self addCachedEntity:aRecord forKey:entityKey];
    /* If the record being added is not a new record and self is not new it is not necessary
    *  to queue the request. This allows use to mimic existing behavior while adding lazy
    *  persistence support.  */
    if(![self isNewRecord] && ![aRecord isNewRecord] &&
            [self persistRecord:aRecord
                        ofClass: aClassname
                        through: aRelationshipClassName])
        return;

    if(!self.hasManyThroughRelationsQueue) {
        self.hasManyThroughRelationsQueue = [NSMutableSet setWithCapacity: 1];
    }

    [self.hasManyThroughRelationsQueue addObject:[ARPersistentQueueEntity entityHavingManyRecord:aRecord
                                                                                     ofClass:aClassname
                                                                                     through:aRelationshipClassName]];
}

- (BOOL)persistRecord:(ActiveRecord *)aRecord
              ofClass:(NSString *)aClassname
              through:(NSString *)aRelationshipClassName { //TODO: Refactor method to support mapping
    Class RelationshipClass = NSClassFromString(aRelationshipClassName);

    NSString *currentId = [self foreignPropertyKey];
    NSString *relId = [aRecord foreignPropertyKey];
    ARLazyFetcher *fetcher = [RelationshipClass lazyFetcher];

    if( ([aRecord isNewRecord] || [aRecord isDirty]) && ![aRecord save]) {
            [self addErrors:aRecord.errors];
            return NO;
    }

    [fetcher where:@"%@ = %@ AND %@ = %@", [currentId stringAsColumnName], self.id, [relId stringAsColumnName], aRecord.id, nil];
    if ([fetcher count] != 0) {
        return YES; // while it couldn't save, it already exists which has same effect.
    }
    NSString *currentIdSelectorString = [NSString stringWithFormat:@"set%@Id:", [[self class] description]];
    NSString *relativeIdSlectorString = [NSString stringWithFormat:@"set%@Id:", aClassname];

    SEL currentIdSelector = NSSelectorFromString(currentIdSelectorString);
    SEL relativeIdSelector = NSSelectorFromString(relativeIdSlectorString);
    ActiveRecord *relationshipRecord = [RelationshipClass newRecord];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [relationshipRecord performSelector:currentIdSelector withObject:self.id];
    [relationshipRecord performSelector:relativeIdSelector withObject:aRecord.id];
#pragma clang diagnostic pop
    return [relationshipRecord save];

}


- (void)removeRecord:(ActiveRecord *)aRecord through:(NSString *)aClassName {
    Class relationsClass = NSClassFromString(aClassName);
    NSString *currentId =  [self foreignPropertyKey]; // [NSString stringWithFormat:@"%@ID", [self recordName]];
    NSString *relId = [aRecord foreignPropertyKey];// [NSString stringWithFormat:@"%@ID", [aRecord recordName]];

    //TODO: There should be a test to ensure that removing a relation also remove the item through the cache.
    NSString *entityKey =  [[aRecord.class className] lowercaseFirst];
    NSString *entityRelationKey = [relationsClass foreignPropertyKey];// [NSString stringWithFormat:@"%@Id", [aClassName lowercaseFirst]] ;
    [self removeCachedEntity:aRecord forKey:entityKey];
    [aRecord setCachedEntity:nil forKey:entityRelationKey];

    ARLazyFetcher *fetcher = [relationsClass lazyFetcher];
    [fetcher where:@"%@ = %@ AND %@ = %@", [currentId stringAsColumnName], self.id, [relId stringAsColumnName], aRecord.id, nil];
    NSArray *records = [fetcher fetchRecords];
    ActiveRecord *record = records.count ? [records objectAtIndex:0] : nil;
    [record dropRecord];
}

#pragma mark - Description

- (NSString *)description {
    NSMutableString *descr = [NSMutableString stringWithFormat:@"%@\n", [self.class className]];
    for (ARColumn *column in [self columns]) {
        [descr appendFormat:@"%@ => %@;", column.columnName, [self valueForColumn:column]];
    }
    return descr;
}

#pragma mark - Drop records

+ (void)dropAllRecords {
    [[self allRecords] makeObjectsPerformSelector:@selector(dropRecord)];
}

- (void)dropRecord {
    if([self hasQueuedRelationships])
        [self save];
    [self beforeDestroy];
    [[ARDatabaseManager sharedManager] dropRecord:self];
    [self afterDestroy];
    [self privateAfterDestroy];
}

#pragma mark - Clear database

+ (void)clearDatabase {
    [[ARDatabaseManager sharedManager] clearDatabase];
}

#pragma mark - Transactions

+ (void)transaction:(ARTransactionBlock)aTransactionBlock {
        [[ARDatabaseManager sharedManager] executeSqlQuery:"BEGIN"];
        @try {
            aTransactionBlock();
            [[ARDatabaseManager sharedManager] executeSqlQuery:"COMMIT"];
        }
        @catch (ARException *exception) {
            [[ARDatabaseManager sharedManager] executeSqlQuery:"ROLLBACK"];
        }
}

#pragma mark - Record Columns

- (NSArray *)columns {
    return [[self class] columns];
}

+ (NSArray *)columns {
    return [[ARSchemaManager sharedInstance] columnsForRecord:self];
}

- (ARColumn *)columnNamed:(NSString *)aColumnName {
    return [[self class] columnNamed:aColumnName];
}

#warning refactor

+ (NSString*) stringMappingForColumnNamed: (NSString*) columnName {
    ARColumn *column = [self columnNamed:columnName];
    return column.mappingName;
}
- (NSString*) stringMappingForColumnNamed: (NSString*) columnName {
   return [[self class] stringMappingForColumnNamed:columnName];
}


+ (ARColumn *)columnNamed:(NSString *)aColumnName {
    ARColumn *cachedColumn = [[ARSchemaManager sharedInstance] columnForRecord:self named:aColumnName];
    if(cachedColumn)
        return cachedColumn;
    NSArray *columns = [self columns];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"columnName = %@", aColumnName];
    NSArray *filteredColumns = [columns filteredArrayUsingPredicate:predicate];
    return filteredColumns.count ? [filteredColumns objectAtIndex:0] : nil;
}

+ (ARColumn *)columnWithSetterNamed:(NSString *)aSetterName {
    ARColumn *cachedColumn =[[ARSchemaManager sharedInstance] columnForRecord:self named:aSetterName];
    if(cachedColumn)
        return cachedColumn;
    NSArray *columns = [self columns];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"setter = %@", aSetterName];
    NSArray *filteredColumns = [columns filteredArrayUsingPredicate:predicate];
    return filteredColumns.count ? [filteredColumns objectAtIndex:0] : nil;
}
- (ARColumn *)columnWithSetterNamed:(NSString *)aSetterName {
    return [[self class] columnWithSetterNamed:aSetterName];
}

+ (ARColumn *)columnWithGetterNamed:(NSString *)aGetterName {
    ARColumn *cachedColumn = [[ARSchemaManager sharedInstance] columnForRecord:self named:aGetterName];
    if(cachedColumn)
        return cachedColumn;
    NSArray *columns = [self columns];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"getter = %@", aGetterName];
    NSArray *filteredColumns = [columns filteredArrayUsingPredicate:predicate];
    return filteredColumns.count ? [filteredColumns objectAtIndex:0] : nil;
}
- (ARColumn *)columnWithGetterNamed:(NSString *)aGetterName {
    return [[self class] columnWithGetterNamed:aGetterName];
}


#pragma mark - Dynamic Properties

+ (void)initializeDynamicAccessors {
    for (ARColumn *column in [self columns]) {
        [ARDynamicAccessor addAccessorForColumn:column];
    }
}

//  KVO-bycycle/Observer
- (void)setValue:(id)aValue forColumn:(ARColumn *)aColumn {
    //    if ([[self recordName] isEqualToString:@"PrimitiveModel"]) {
    //        NSLog(@"%@ %@", aValue, aColumn.columnName);
    //    }
    if (aColumn == nil) {
        return;
    }

    id oldValue = objc_getAssociatedObject(self, aColumn.columnKey);
    if ( (oldValue == nil && aValue == nil) || ([oldValue isEqual:aValue]) ) {
        return;
    }
    
    objc_setAssociatedObject(self,
                             aColumn.columnKey,
                             nil,
                             aColumn.associationPolicy);
    
    objc_setAssociatedObject(self,
                             aColumn.columnKey,
                             aValue,
                             aColumn.associationPolicy);
    
    [self.changedColumns addObject:aColumn];
}

- (void) loadValue:(id) value forColumn:(ARColumn *) column {
    [self setValue:[column deserializedValue:value] forColumn:column];

    if(!column.immutable) {
        NSString *key = [NSString stringWithCString:column.columnKey encoding:NSStringEncodingConversionAllowLossy];
        self.deserializedCache[key] = @([[value description] hash]);
    }
}

- (id)valueForImmutableColumn:(ARColumn *)column { //todo: optimize, perhaps should check only on save
    id object = objc_getAssociatedObject(self, column.columnKey);

    if(!column.immutable && ![self.changedColumns containsObject:column]) {
        NSString *key = [NSString stringWithCString:column.columnKey
                                           encoding:NSStringEncodingConversionAllowLossy];
        NSNumber *oldHash = self.deserializedCache[key];
        NSNumber *newHash = @([[object description] hash]);

        if([oldHash intValue] !=  [newHash intValue]) {
            [self.changedColumns addObject:column];
            self.deserializedCache[key] =  newHash ;//@([object hash]);
        }
    }

    return object;
}

- (id)valueForColumn:(ARColumn *)aColumn {
    id object = objc_getAssociatedObject(self, aColumn.columnKey);
    return object;
}

- (id)valueForUndefinedKey:(NSString *)aKey {
    ARColumn *column = [self columnNamed:aKey];
    if (column == nil) {
        return [super valueForUndefinedKey:aKey];
    }else {
        return [self valueForColumn:column];
    }
}

- (void)setValue:(id)value forUndefinedKey:(NSString *)aKey {
    ARColumn *column = [self columnNamed:aKey];
    if (column == nil) {
        [super setValue:value forUndefinedKey:aKey];
    }else {
        [self setValue:value
             forColumn:column];
    }
}

#pragma mark - Indices

+ (void)initializeIndices {
    //  nothing goes there
}

+ (void)initializeMapping {

}

+ (void)addMappingOn:(NSString*)properyName column: (NSString*) columnName {
    [[ARSchemaManager sharedInstance] addMappingOnProperty:properyName
                                                    column:columnName
                                                  ofRecord:self];

}
+ (void)addMappingOn:(NSString*)properyName mapping: (NSDictionary*) mapping {
    [[ARSchemaManager sharedInstance] addMappingOnProperty:properyName
                                                   mapping:mapping
                                                  ofRecord:self];
}
+ (void)addIndexOn:(NSString *)aField {
    [[ARSchemaManager sharedInstance] addIndexOnColumn:aField
                                              ofRecord:self];
}

#pragma mark - Configuration

+ (void)applyConfiguration:(ARConfigurationBlock)configBlock {
    NSAssert(configBlock, @"ARConfigurationBlock should not be nil");
    
    ARConfiguration *config = [ARConfiguration new];
    configBlock(config);
    ARDatabaseManager *manager = [ARDatabaseManager sharedManager];
    [manager applyConfiguration:config];
}

#pragma mark - Extentions
+ (ARLazyFetcher *) query {
    return [self lazyFetcher];
}

+ (instancetype) findById: (id) record_id {
    return [[self lazyFetcher] findById:record_id];
}

+ (instancetype) findByKey: (id) key value: (id) value {
    id result =[[self lazyFetcher] findByKey:key value:value] ;
    return result;
}

+ (instancetype) findOrBuildByKey: (id) key value: (id) value {
    id instance =   [[self lazyFetcher] findByKey:key value:value];
    if(!instance)
        instance = [self new:@{key : value}];

    return instance;
}

+ (NSArray *) findAllByKey: (id) key value: (id) value {
    return [[self lazyFetcher] findAllByKey:key value:value];
}

+ (NSArray *) findAllByConditions: (NSDictionary *) conditions {
    return [[self lazyFetcher] findAllByConditions:conditions];
}

+ (NSArray*) findByConditions: (NSDictionary *) conditions {
    return [[self lazyFetcher] findByConditions:conditions];
}


- (instancetype) recordSaved {

    if([self save])
        return self;

    return nil;
}


+ (BOOL) savePointTransaction: (ARSavePointTransactionBlock) transaction {
    NSString *savePointSeed = [NSString stringWithFormat:@"liberty"];
    NSString *savePointName = [self savepointMD5Hash: [NSString stringWithFormat:@"%p", savePointSeed] ];
    return [self savePoint:savePointName transaction:transaction];
}

+ (BOOL) savePoint: (NSString *)name transaction: (ARSavePointTransactionBlock) transaction {
    BOOL failure = NO;

    @try {
        [[ARDatabaseManager sharedManager] executeSqlQuery:[[NSString stringWithFormat:@"SAVEPOINT '%@'", name] UTF8String]];
        ARTransactionState *status = [ARTransactionState stateWithName:name];
        transaction(status);

        if((failure = status.isRolledBack))
            [[ARDatabaseManager sharedManager] executeSqlQuery:[[NSString stringWithFormat:@"ROLLBACK TRANSACTION TO SAVEPOINT '%@'", name] UTF8String]];

        [[ARDatabaseManager sharedManager] executeSqlQuery:[[NSString stringWithFormat:@"RELEASE SAVEPOINT '%@' ", name] UTF8String]];

    } @catch (ARException *exception) {
        failure = YES;
        [[ARDatabaseManager sharedManager] executeSqlQuery:[[NSString stringWithFormat:@"ROLLBACK TRANSACTION TO SAVEPOINT '%@'", name] UTF8String]];
        [[ARDatabaseManager sharedManager] executeSqlQuery:[[NSString stringWithFormat:@"RELEASE SAVEPOINT '%@' ", name] UTF8String]];

    }
    return !failure;
}

+ (NSString *) savepointMD5Hash:(NSString *)str {
    const char *cStr = [str UTF8String];
    unsigned char result[16];
    CC_MD5( cStr, strlen(cStr), result );

    return [NSString stringWithFormat:
                             @"savePoint_%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
                             result[0], result[1], result[2], result[3],
                             result[4], result[5], result[6], result[7],
                             result[8], result[9], result[10], result[11],
                             result[12], result[13], result[14], result[15]
    ];
}

@end
