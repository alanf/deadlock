//
//  DeadlockTests.m
//  DeadlockTests
//
//  Created by Alan Fineberg on 4/8/16.
//

#import <XCTest/XCTest.h>
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import "Account.h"


@interface NSManagedObjectContext (_NSCoreDataSPI)

// This is a private method in `NSManagedObjectContext` which increases retain count,
// and doesn't decrease it until after its block argument is called.
//
// The block which would decrease the retain count can end up waiting behind other things on the run loop, and never get called.
// If this happens, the managed object context will live a long time, and start polluting the runloop with `processPendingChanges` calls.
// In a test environment where multiple `NSManagedObjectContext`s are created for each test, the run loop is soon overwhelmed with `processPendingChanges` calls and bad things begin to happen.
- (void)performWithOptions:(unsigned int)arg1 andBlock:(dispatch_block_t)arg2;

@end

@interface SDManagedObjectContext : NSManagedObjectContext

@end

@implementation SDManagedObjectContext

static NSHashTable *instances = nil;

- (instancetype)initWithConcurrencyType:(NSManagedObjectContextConcurrencyType)ct
{
    if (!instances) {
       instances = [[NSHashTable alloc] initWithOptions:NSHashTableWeakMemory capacity:100];
    }
    
    [instances addObject:self];
    return [super initWithConcurrencyType:ct];
}

- (void)dealloc
{
    // Not called unless the runloop can spin because performWithOptions:andBlock increases the retain count.
    [instances removeObject:self];
    NSLog(@"dealloc: %@ instances remain", @(instances.count));
}

- (void)processPendingChanges;
{
    // Since the contexts were never dealloced, contexts will accumulate, and when the run loop finally gets to run, it will get a stampeding herd of `processPendingChanges` calls.
    // If lots of contexts (~1800-2000) try to call this during the runloop, queues will starve and deadlocks will occur. And everything slows down.
    NSLog(@"%@ processed pending changes", self);
    [super processPendingChanges];
}

- (void)performWithOptions:(unsigned int)arg1 andBlock:(dispatch_block_t)arg2;
{
     __weak SDManagedObjectContext *weakSelf = self;
    NSLog(@"About to be retained %@", self);
    [super performWithOptions:arg1 andBlock:^{
        arg2();
        NSLog(@"in callback %@", weakSelf);
    }];
    NSLog(@"My retain count just went up %@", self);
}

@end


@interface DeadlockTests : XCTestCase

@property Account *account;

@end

@implementation DeadlockTests

static int32_t testCount = 0;

- (void)setUp {
    [super setUp];
    
    NSString *modelPath = [[NSBundle mainBundle] pathForResource:@"Deadlock" ofType:@"momd"];
    NSURL *modelURL = [NSURL fileURLWithPath:modelPath];
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    
    NSURL *path = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    
    NSURL *storeURL = [path URLByAppendingPathComponent:@"DeadlockSQL.sqlite"];
    NSError *error = nil;
    [coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:storeURL options:nil error:&error];
    
    SDManagedObjectContext *context = [[SDManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    context.persistentStoreCoordinator = coordinator;
    context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;
    XCTAssertNil(context.undoManager);
    
    NSEntityDescription *entityDescription = [NSEntityDescription entityForName:@"Account" inManagedObjectContext:context];
    Account *account = [[Account alloc] initWithEntity:entityDescription insertIntoManagedObjectContext:context];
    account.name = @"AAAAA";
    [context save:NULL];
    
    self.account = account;
}

- (void)tearDown {
    [super tearDown];
    testCount += 1;

    if (testCount > 30) {
        // Yay! We finally get to spin the runloop.
        // Now the queue will drain and deallocs will actually happen...
        // But also notice that the runloop gets slammed with `processPendingChanges` calls.
        // We depend on `processPendingChanges` calls clearing out, because if they happen on every runloop, it gets costly.
        // But, at a larger scale, they may not dissipate very quickly.
        NSDate *currentDate = [NSDate date];
        NSDate *timeoutDate = [currentDate dateByAddingTimeInterval:5];
        do {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:MIN(5, .001)]];
            currentDate = [NSDate date];
        } while ([currentDate compare:timeoutDate] != NSOrderedDescending);
    }
}

// Create a number of very similar tests so we can see the accumulation of contexts.
- (void)testExample {
    XCTAssertEqualObjects(self.account.name, @"AAAAA");
    
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
    
    self.account.name = @"bar";
}

- (void)testExample2 {
    XCTAssertEqualObjects(self.account.name, @"AAAAA");
    
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
    self.account.name = @"bar";
}

- (void)testExample3 {
    XCTAssertEqualObjects(self.account.name, @"AAAAA");
    
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
    self.account.name = @"bar";
}

- (void)testExample4 {
    XCTAssertEqualObjects(self.account.name, @"AAAAA");
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
}

- (void)testExample5 {
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
}

- (void)testExample6 {
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
}

- (void)testExample7 {
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
}

- (void)testExample8 {
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
}

- (void)testExample9 {
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
}

- (void)testExample10 {
    self.account.name = @"foo";
    [self.account.managedObjectContext save:NULL];
}

- (void)testExample11 {
    self.account.name = @"foo";
}
- (void)testExample12 {
    self.account.name = @"foo";
}
- (void)testExample13 {
    self.account.name = @"foo";
}
- (void)testExample14 {
    self.account.name = @"foo";
}
- (void)testExample15 {
    self.account.name = @"foo";
}
- (void)testExample16 {
    self.account.name = @"foo";
}
- (void)testExample17 {
    self.account.name = @"foo";
}
- (void)testExample18 {
    self.account.name = @"foo";
}
- (void)testExample19 {
    self.account.name = @"foo";
}
- (void)testExample20 {
    self.account.name = @"foo";
}
- (void)testExample21 {
    self.account.name = @"foo";
}
- (void)testExample22 {
    self.account.name = @"foo";
}
- (void)testExample23 {
    self.account.name = @"foo";
}
- (void)testExample24 {
    self.account.name = @"foo";
}
- (void)testExample25 {
    self.account.name = @"foo";
}
- (void)testExample26 {
    self.account.name = @"foo";
}
- (void)testExample27 {
    self.account.name = @"foo";
}
- (void)testExample28 {
    self.account.name = @"foo";
}
- (void)testExample29 {
    self.account.name = @"foo";
}
- (void)testExample30 {
    self.account.name = @"foo";
}
- (void)testExample31 {
    self.account.name = @"foo";
}

@end
