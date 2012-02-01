#import "ActiveRecord.h"
#import "ARDatabaseManager.h"
#import "NSString+lowercaseFirst.h"
#import <objc/runtime.h>
#import "ARObjectProperty.h"
#import "ARValidations.h"
#import "ARValidatableProtocol.h"
#import "ARErrorHelper.h"

#pragma mark - Dynamic functions proptotypes
NSArray* dynamicallyFind(id self, SEL _cmd, id arg);

NSArray* dynamicallyFind(id self, SEL _cmd, id arg){
    NSLog(@"dynamicallyFind resolving %@", arg);
    NSString *selector = NSStringFromSelector(_cmd);
    NSString *searchKey = [selector substringFromIndex:6];
    searchKey = [searchKey stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@":"]];
    searchKey = [searchKey lowercaseFirst];
    NSArray *records = [[ARDatabaseManager sharedInstance] allRecordsWithName:[[self class] description] 
                                                                     whereKey:searchKey 
                                                                     hasValue:arg];
    return records;
}

@implementation ActiveRecord

@synthesize id;
//@synthesize errorMessages;

#pragma mark - validations

VALIDATION_HELPER

+ (NSString *)className {
    return [[self class] description];
}

- (NSString *)recordName {
    return [[self class] tableName];
}

+ (void)validateField:(NSString *)aField asUnique:(BOOL)aUnique {
    if(nil == uniqueFields){
        uniqueFields = [[NSMutableSet alloc] init];
    }
    
    BOOL contains = [uniqueFields containsObject:aField];
    if(aUnique){
        if(contains){
            return;
        }
        [uniqueFields addObject:aField];
        return;
    }
    if(contains){
        [uniqueFields removeObject:aField];
        return;
    }    
}

+ (void)validateField:(NSString *)aField asPresence:(BOOL)aPresence {
    if(nil == presenceFields){
        presenceFields = [[NSMutableSet alloc] init];
    }
    BOOL contains = [presenceFields containsObject:aField];
    if(aPresence){
        if(contains){
            return;
        }
        [presenceFields addObject:aField];
        return;
    }
    if(contains){
        [presenceFields removeObject:aField];
        return;
    } 
}

- (void)resetErrors {
    [errorMessages release];
    errorMessages = nil;
}

- (void)addError:(NSString *)errMessage {
    if(nil == errorMessages){
        errorMessages = [[NSMutableSet alloc] init];
    }
    [errorMessages addObject:errMessage];
}

- (void)logErrors {
    for(NSString *error in errorMessages){
        NSLog(@"%@", error);
    }
}

- (void)validate {
    if(![self conformsToProtocol:@protocol(ARValidatableProtocol)]){
        return;
    }
    [self validatePresence];
    [self validateUniqueness];
}

- (void)validateUniqueness {
    NSString *recordName = [self recordName];
    for(NSString *uniqueField in uniqueFields){
        id aValue = [self valueForKey:uniqueField];
        NSArray *records = [[ARDatabaseManager sharedInstance] allRecordsWithName:recordName 
                                                                         whereKey:uniqueField 
                                                                         hasValue:aValue];
        if([records count]){
            NSString *errMessage = [NSString stringWithFormat:@"%@ '%@' %@", 
                                    uniqueField, 
                                    aValue,
                                    AR_Error(kARFieldAlreadyExists)];
            [self addError:errMessage];
        }
    }
}

- (void)validatePresence {
    for(NSString *presenceField in presenceFields){
        NSString *aValue = [self valueForKey:presenceField];
        if(aValue == nil || [aValue length] == 0){
            NSString *errMessage = [NSString stringWithFormat:@"%@ %@", 
                                    presenceField, 
                                    AR_Error(kARFieldCantBeBlank)];
            [self addError:errMessage];
        }
    }
}

- (void)initialize {
    
}

#pragma mark - 

+ (const char *)sqlOnCreate {
    NSMutableString *sqlString = [NSMutableString stringWithFormat:@"create table %@(id integer primary key ", 
                                  [self performSelector:@selector(tableName)]];
    NSArray *properties = [self performSelector:@selector(properties)];
    if([properties count] == 0){
        return NULL;
    }
    Class propertyClass = nil;
    for(ARObjectProperty *property in properties){
        propertyClass = NSClassFromString(property.propertyType);
        [sqlString appendFormat:@", %@ %s", property.propertyName, 
         [propertyClass performSelector:@selector(sqlType)]];
    }
    [sqlString appendFormat:@")"];
    return [sqlString UTF8String];
}

- (const char *)sqlOnSave {
    NSArray *properties = [[self class] performSelector:@selector(properties)];
    if([properties count] == 0){
        return NULL;
    }
    NSMutableArray *existedProperties = [[NSMutableArray alloc] init];
    ARObjectProperty *property = nil;
    for(property in properties){
        id value = [self valueForKey:property.propertyName];
        if(nil != value){
            [existedProperties addObject:property];
        }
    }
    if([existedProperties count] == 0){
        return NULL;
    }
    
    NSMutableString *sqlString = [NSMutableString stringWithFormat:@"insert into %@(", 
                                  [[self class] performSelector:@selector(tableName)]];
    NSMutableString *sqlValues = [[NSMutableString alloc] initWithFormat:@" values("];
    
    int index = 0;
    property = [existedProperties objectAtIndex:index++];
    id propertyValue = [self valueForKey:property.propertyName];
    [sqlString appendFormat:@"%@", property.propertyName];
    [sqlValues appendFormat:@"%@", [propertyValue performSelector:@selector(toSql)]];
    
    for(;index < [properties count] - 1;index++){
        property = [properties objectAtIndex:index];
        id propertyValue = [self valueForKey:property.propertyName];
        [sqlString appendFormat:@", %@", property.propertyName];
        [ sqlValues appendFormat:@", %@", [propertyValue performSelector:@selector(toSql)]];
    }
    [sqlValues appendString:@") "];
    [sqlString appendString:@") "];
    [sqlString appendString:sqlValues];
    return [sqlString UTF8String];
}

+ (NSString *)tableName {
    return [NSString stringWithFormat:@"ar%@", [[self class] description]];
}

+ (BOOL)resolveInstanceMethod:(SEL)name {
  return NO;
}

+ (BOOL)resolveClassMethod:(SEL)aSel {
    NSString *selectorName = NSStringFromSelector(aSel);
    if([selectorName hasPrefix:@"findBy"]){
        Class selfMetaClass = objc_getMetaClass([[[self class] description]  UTF8String]);
        class_addMethod(selfMetaClass, aSel, (IMP)dynamicallyFind, "[]@:@");
        return YES;
    }
    return [super resolveInstanceMethod:aSel];
}

+ (id)newRecord {
  Class RecordClass = [self class];
  id record = [[RecordClass alloc] init];
  return record;
}

+ (NSArray *)allRecords {
  NSString *recordName = [[self class] description];
  return [[ARDatabaseManager sharedInstance] allRecordsWithName:recordName];
}

+ (id)findById:(NSNumber *)anId{
  NSString *recordName = [[self class] description];
  return [[ARDatabaseManager sharedInstance] findRecord:recordName byId:anId];
}

- (BOOL)isValid {
    [self resetErrors];
    [self validate];        
    [self logErrors];
    return nil == errorMessages;
}

- (BOOL)save {
    const char *sql = [self sqlOnSave];
    if(NULL != sql){
        [[ARDatabaseManager sharedInstance] executeSqlQuery:sql];
    }
    return NO;
}

@end