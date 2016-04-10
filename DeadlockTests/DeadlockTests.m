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


// Here's a short demo meant to illustrate the very beginnings of a "Deadly Cycle" that leads to deadlock:

// 1. We use `NSManagedObjectContext`s during test, they increase their own retain count and put work on a queue as part of saving changes.
// 2. The context's queue never gets the chance to drain while the tests run, so they stick around, and may continue doing idle work.
// 3. By the time our `NSRunLoop` finally is able to drain, it may be thrashed beyond all hope by scheduled tasks such as context's `processPendingChanges`.
// 4. Tests slow down, and work that's placed on the queue never pops. Deadlocks and/or timeouts occur.
// 5. In reality, it would take many hundreds of leaked contexts before issues begin to clearly arise.


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

    if (testCount > 400) {
        // Yay! We finally get to spin the runloop.
        // Now the queue will drain and deallocs will actually happen...
        // But also notice that the runloop gets slammed with `processPendingChanges` calls.
        // We depend on `processPendingChanges` calls clearing out, because if they happen on every runloop, it gets costly.
        // But, at a larger scale, they may not dissipate very quickly.
        // And I *believe* that the NSRunLoop aborts draining its lower priority queues if it spends too much on other tasks.
        NSDate *currentDate = [NSDate date];
        NSDate *timeoutDate = [currentDate dateByAddingTimeInterval:.1];
        do {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:MIN(.1, .001)]];
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

- (void)testExample32 {
    self.account.name = @"foo";
}
- (void)testExample33 {
    self.account.name = @"foo";
}
- (void)testExample34 {
    self.account.name = @"foo";
}
- (void)testExample35 {
    self.account.name = @"foo";
}
- (void)testExample36 {
    self.account.name = @"foo";
}
- (void)testExample37 {
    self.account.name = @"foo";
}
- (void)testExample38 {
    self.account.name = @"foo";
}
- (void)testExample39 {
    self.account.name = @"foo";
}
- (void)testExample40 {
    self.account.name = @"foo";
}
- (void)testExample41 {
    self.account.name = @"foo";
}
- (void)testExample42 {
    self.account.name = @"foo";
}
- (void)testExample43 {
    self.account.name = @"foo";
}
- (void)testExample44 {
    self.account.name = @"foo";
}
- (void)testExample45 {
    self.account.name = @"foo";
}
- (void)testExample46 {
    self.account.name = @"foo";
}
- (void)testExample47 {
    self.account.name = @"foo";
}
- (void)testExample48 {
    self.account.name = @"foo";
}
- (void)testExample49 {
    self.account.name = @"foo";
}
- (void)testExample50 {
    self.account.name = @"foo";
}
- (void)testExample51 {
    self.account.name = @"foo";
}
- (void)testExample52 {
    self.account.name = @"foo";
}
- (void)testExample53 {
    self.account.name = @"foo";
}
- (void)testExample54 {
    self.account.name = @"foo";
}
- (void)testExample55 {
    self.account.name = @"foo";
}
- (void)testExample56 {
    self.account.name = @"foo";
}
- (void)testExample57 {
    self.account.name = @"foo";
}
- (void)testExample58 {
    self.account.name = @"foo";
}
- (void)testExample59 {
    self.account.name = @"foo";
}
- (void)testExample60 {
    self.account.name = @"foo";
}
- (void)testExample61 {
    self.account.name = @"foo";
}
- (void)testExample62 {
    self.account.name = @"foo";
}
- (void)testExample63 {
    self.account.name = @"foo";
}
- (void)testExample64 {
    self.account.name = @"foo";
}
- (void)testExample65 {
    self.account.name = @"foo";
}
- (void)testExample66 {
    self.account.name = @"foo";
}
- (void)testExample67 {
    self.account.name = @"foo";
}
- (void)testExample68 {
    self.account.name = @"foo";
}
- (void)testExample69 {
    self.account.name = @"foo";
}
- (void)testExample70 {
    self.account.name = @"foo";
}
- (void)testExample71 {
    self.account.name = @"foo";
}
- (void)testExample72 {
    self.account.name = @"foo";
}
- (void)testExample73 {
    self.account.name = @"foo";
}
- (void)testExample74 {
    self.account.name = @"foo";
}
- (void)testExample75 {
    self.account.name = @"foo";
}
- (void)testExample76 {
    self.account.name = @"foo";
}
- (void)testExample77 {
    self.account.name = @"foo";
}
- (void)testExample78 {
    self.account.name = @"foo";
}
- (void)testExample79 {
    self.account.name = @"foo";
}
- (void)testExample80 {
    self.account.name = @"foo";
}
- (void)testExample81 {
    self.account.name = @"foo";
}
- (void)testExample82 {
    self.account.name = @"foo";
}
- (void)testExample83 {
    self.account.name = @"foo";
}
- (void)testExample84 {
    self.account.name = @"foo";
}
- (void)testExample85 {
    self.account.name = @"foo";
}
- (void)testExample86 {
    self.account.name = @"foo";
}
- (void)testExample87 {
    self.account.name = @"foo";
}
- (void)testExample88 {
    self.account.name = @"foo";
}
- (void)testExample89 {
    self.account.name = @"foo";
}
- (void)testExample90 {
    self.account.name = @"foo";
}
- (void)testExample91 {
    self.account.name = @"foo";
}
- (void)testExample92 {
    self.account.name = @"foo";
}
- (void)testExample93 {
    self.account.name = @"foo";
}
- (void)testExample94 {
    self.account.name = @"foo";
}
- (void)testExample95 {
    self.account.name = @"foo";
}
- (void)testExample96 {
    self.account.name = @"foo";
}
- (void)testExample97 {
    self.account.name = @"foo";
}
- (void)testExample98 {
    self.account.name = @"foo";
}
- (void)testExample99 {
    self.account.name = @"foo";
}
- (void)testExample100 {
    self.account.name = @"foo";
}
- (void)testExample101 {
    self.account.name = @"foo";
}
- (void)testExample102 {
    self.account.name = @"foo";
}
- (void)testExample103 {
    self.account.name = @"foo";
}
- (void)testExample104 {
    self.account.name = @"foo";
}
- (void)testExample105 {
    self.account.name = @"foo";
}
- (void)testExample106 {
    self.account.name = @"foo";
}
- (void)testExample107 {
    self.account.name = @"foo";
}
- (void)testExample108 {
    self.account.name = @"foo";
}
- (void)testExample109 {
    self.account.name = @"foo";
}
- (void)testExample110 {
    self.account.name = @"foo";
}
- (void)testExample111 {
    self.account.name = @"foo";
}
- (void)testExample112 {
    self.account.name = @"foo";
}
- (void)testExample113 {
    self.account.name = @"foo";
}
- (void)testExample114 {
    self.account.name = @"foo";
}
- (void)testExample115 {
    self.account.name = @"foo";
}
- (void)testExample116 {
    self.account.name = @"foo";
}
- (void)testExample117 {
    self.account.name = @"foo";
}
- (void)testExample118 {
    self.account.name = @"foo";
}
- (void)testExample119 {
    self.account.name = @"foo";
}
- (void)testExample120 {
    self.account.name = @"foo";
}
- (void)testExample121 {
    self.account.name = @"foo";
}
- (void)testExample122 {
    self.account.name = @"foo";
}
- (void)testExample123 {
    self.account.name = @"foo";
}
- (void)testExample124 {
    self.account.name = @"foo";
}
- (void)testExample125 {
    self.account.name = @"foo";
}
- (void)testExample126 {
    self.account.name = @"foo";
}
- (void)testExample127 {
    self.account.name = @"foo";
}
- (void)testExample128 {
    self.account.name = @"foo";
}
- (void)testExample129 {
    self.account.name = @"foo";
}
- (void)testExample130 {
    self.account.name = @"foo";
}
- (void)testExample131 {
    self.account.name = @"foo";
}
- (void)testExample132 {
    self.account.name = @"foo";
}
- (void)testExample133 {
    self.account.name = @"foo";
}
- (void)testExample134 {
    self.account.name = @"foo";
}
- (void)testExample135 {
    self.account.name = @"foo";
}
- (void)testExample136 {
    self.account.name = @"foo";
}
- (void)testExample137 {
    self.account.name = @"foo";
}
- (void)testExample138 {
    self.account.name = @"foo";
}
- (void)testExample139 {
    self.account.name = @"foo";
}
- (void)testExample140 {
    self.account.name = @"foo";
}
- (void)testExample141 {
    self.account.name = @"foo";
}
- (void)testExample142 {
    self.account.name = @"foo";
}
- (void)testExample143 {
    self.account.name = @"foo";
}
- (void)testExample144 {
    self.account.name = @"foo";
}
- (void)testExample145 {
    self.account.name = @"foo";
}
- (void)testExample146 {
    self.account.name = @"foo";
}
- (void)testExample147 {
    self.account.name = @"foo";
}
- (void)testExample148 {
    self.account.name = @"foo";
}
- (void)testExample149 {
    self.account.name = @"foo";
}
- (void)testExample150 {
    self.account.name = @"foo";
}
- (void)testExample151 {
    self.account.name = @"foo";
}
- (void)testExample152 {
    self.account.name = @"foo";
}
- (void)testExample153 {
    self.account.name = @"foo";
}
- (void)testExample154 {
    self.account.name = @"foo";
}
- (void)testExample155 {
    self.account.name = @"foo";
}
- (void)testExample156 {
    self.account.name = @"foo";
}
- (void)testExample157 {
    self.account.name = @"foo";
}
- (void)testExample158 {
    self.account.name = @"foo";
}
- (void)testExample159 {
    self.account.name = @"foo";
}
- (void)testExample160 {
    self.account.name = @"foo";
}
- (void)testExample161 {
    self.account.name = @"foo";
}
- (void)testExample162 {
    self.account.name = @"foo";
}
- (void)testExample163 {
    self.account.name = @"foo";
}
- (void)testExample164 {
    self.account.name = @"foo";
}
- (void)testExample165 {
    self.account.name = @"foo";
}
- (void)testExample166 {
    self.account.name = @"foo";
}
- (void)testExample167 {
    self.account.name = @"foo";
}
- (void)testExample168 {
    self.account.name = @"foo";
}
- (void)testExample169 {
    self.account.name = @"foo";
}
- (void)testExample170 {
    self.account.name = @"foo";
}
- (void)testExample171 {
    self.account.name = @"foo";
}
- (void)testExample172 {
    self.account.name = @"foo";
}
- (void)testExample173 {
    self.account.name = @"foo";
}
- (void)testExample174 {
    self.account.name = @"foo";
}
- (void)testExample175 {
    self.account.name = @"foo";
}
- (void)testExample176 {
    self.account.name = @"foo";
}
- (void)testExample177 {
    self.account.name = @"foo";
}
- (void)testExample178 {
    self.account.name = @"foo";
}
- (void)testExample179 {
    self.account.name = @"foo";
}
- (void)testExample180 {
    self.account.name = @"foo";
}
- (void)testExample181 {
    self.account.name = @"foo";
}
- (void)testExample182 {
    self.account.name = @"foo";
}
- (void)testExample183 {
    self.account.name = @"foo";
}
- (void)testExample184 {
    self.account.name = @"foo";
}
- (void)testExample185 {
    self.account.name = @"foo";
}
- (void)testExample186 {
    self.account.name = @"foo";
}
- (void)testExample187 {
    self.account.name = @"foo";
}
- (void)testExample188 {
    self.account.name = @"foo";
}
- (void)testExample189 {
    self.account.name = @"foo";
}
- (void)testExample190 {
    self.account.name = @"foo";
}
- (void)testExample191 {
    self.account.name = @"foo";
}
- (void)testExample192 {
    self.account.name = @"foo";
}
- (void)testExample193 {
    self.account.name = @"foo";
}
- (void)testExample194 {
    self.account.name = @"foo";
}
- (void)testExample195 {
    self.account.name = @"foo";
}
- (void)testExample196 {
    self.account.name = @"foo";
}
- (void)testExample197 {
    self.account.name = @"foo";
}
- (void)testExample198 {
    self.account.name = @"foo";
}
- (void)testExample199 {
    self.account.name = @"foo";
}
- (void)testExample200 {
    self.account.name = @"foo";
}
- (void)testExample201 {
    self.account.name = @"foo";
}
- (void)testExample202 {
    self.account.name = @"foo";
}
- (void)testExample203 {
    self.account.name = @"foo";
}
- (void)testExample204 {
    self.account.name = @"foo";
}
- (void)testExample205 {
    self.account.name = @"foo";
}
- (void)testExample206 {
    self.account.name = @"foo";
}
- (void)testExample207 {
    self.account.name = @"foo";
}
- (void)testExample208 {
    self.account.name = @"foo";
}
- (void)testExample209 {
    self.account.name = @"foo";
}
- (void)testExample210 {
    self.account.name = @"foo";
}
- (void)testExample211 {
    self.account.name = @"foo";
}
- (void)testExample212 {
    self.account.name = @"foo";
}
- (void)testExample213 {
    self.account.name = @"foo";
}
- (void)testExample214 {
    self.account.name = @"foo";
}
- (void)testExample215 {
    self.account.name = @"foo";
}
- (void)testExample216 {
    self.account.name = @"foo";
}
- (void)testExample217 {
    self.account.name = @"foo";
}
- (void)testExample218 {
    self.account.name = @"foo";
}
- (void)testExample219 {
    self.account.name = @"foo";
}
- (void)testExample220 {
    self.account.name = @"foo";
}
- (void)testExample221 {
    self.account.name = @"foo";
}
- (void)testExample222 {
    self.account.name = @"foo";
}
- (void)testExample223 {
    self.account.name = @"foo";
}
- (void)testExample224 {
    self.account.name = @"foo";
}
- (void)testExample225 {
    self.account.name = @"foo";
}
- (void)testExample226 {
    self.account.name = @"foo";
}
- (void)testExample227 {
    self.account.name = @"foo";
}
- (void)testExample228 {
    self.account.name = @"foo";
}
- (void)testExample229 {
    self.account.name = @"foo";
}
- (void)testExample230 {
    self.account.name = @"foo";
}
- (void)testExample231 {
    self.account.name = @"foo";
}
- (void)testExample232 {
    self.account.name = @"foo";
}
- (void)testExample233 {
    self.account.name = @"foo";
}
- (void)testExample234 {
    self.account.name = @"foo";
}
- (void)testExample235 {
    self.account.name = @"foo";
}
- (void)testExample236 {
    self.account.name = @"foo";
}
- (void)testExample237 {
    self.account.name = @"foo";
}
- (void)testExample238 {
    self.account.name = @"foo";
}
- (void)testExample239 {
    self.account.name = @"foo";
}
- (void)testExample240 {
    self.account.name = @"foo";
}
- (void)testExample241 {
    self.account.name = @"foo";
}
- (void)testExample242 {
    self.account.name = @"foo";
}
- (void)testExample243 {
    self.account.name = @"foo";
}
- (void)testExample244 {
    self.account.name = @"foo";
}
- (void)testExample245 {
    self.account.name = @"foo";
}
- (void)testExample246 {
    self.account.name = @"foo";
}
- (void)testExample247 {
    self.account.name = @"foo";
}
- (void)testExample248 {
    self.account.name = @"foo";
}
- (void)testExample249 {
    self.account.name = @"foo";
}
- (void)testExample250 {
    self.account.name = @"foo";
}
- (void)testExample251 {
    self.account.name = @"foo";
}
- (void)testExample252 {
    self.account.name = @"foo";
}
- (void)testExample253 {
    self.account.name = @"foo";
}
- (void)testExample254 {
    self.account.name = @"foo";
}
- (void)testExample255 {
    self.account.name = @"foo";
}
- (void)testExample256 {
    self.account.name = @"foo";
}
- (void)testExample257 {
    self.account.name = @"foo";
}
- (void)testExample258 {
    self.account.name = @"foo";
}
- (void)testExample259 {
    self.account.name = @"foo";
}
- (void)testExample260 {
    self.account.name = @"foo";
}
- (void)testExample261 {
    self.account.name = @"foo";
}
- (void)testExample262 {
    self.account.name = @"foo";
}
- (void)testExample263 {
    self.account.name = @"foo";
}
- (void)testExample264 {
    self.account.name = @"foo";
}
- (void)testExample265 {
    self.account.name = @"foo";
}
- (void)testExample266 {
    self.account.name = @"foo";
}
- (void)testExample267 {
    self.account.name = @"foo";
}
- (void)testExample268 {
    self.account.name = @"foo";
}
- (void)testExample269 {
    self.account.name = @"foo";
}
- (void)testExample270 {
    self.account.name = @"foo";
}
- (void)testExample271 {
    self.account.name = @"foo";
}
- (void)testExample272 {
    self.account.name = @"foo";
}
- (void)testExample273 {
    self.account.name = @"foo";
}
- (void)testExample274 {
    self.account.name = @"foo";
}
- (void)testExample275 {
    self.account.name = @"foo";
}
- (void)testExample276 {
    self.account.name = @"foo";
}
- (void)testExample277 {
    self.account.name = @"foo";
}
- (void)testExample278 {
    self.account.name = @"foo";
}
- (void)testExample279 {
    self.account.name = @"foo";
}
- (void)testExample280 {
    self.account.name = @"foo";
}
- (void)testExample281 {
    self.account.name = @"foo";
}
- (void)testExample282 {
    self.account.name = @"foo";
}
- (void)testExample283 {
    self.account.name = @"foo";
}
- (void)testExample284 {
    self.account.name = @"foo";
}
- (void)testExample285 {
    self.account.name = @"foo";
}
- (void)testExample286 {
    self.account.name = @"foo";
}
- (void)testExample287 {
    self.account.name = @"foo";
}
- (void)testExample288 {
    self.account.name = @"foo";
}
- (void)testExample289 {
    self.account.name = @"foo";
}
- (void)testExample290 {
    self.account.name = @"foo";
}
- (void)testExample291 {
    self.account.name = @"foo";
}
- (void)testExample292 {
    self.account.name = @"foo";
}
- (void)testExample293 {
    self.account.name = @"foo";
}
- (void)testExample294 {
    self.account.name = @"foo";
}
- (void)testExample295 {
    self.account.name = @"foo";
}
- (void)testExample296 {
    self.account.name = @"foo";
}
- (void)testExample297 {
    self.account.name = @"foo";
}
- (void)testExample298 {
    self.account.name = @"foo";
}
- (void)testExample299 {
    self.account.name = @"foo";
}
- (void)testExample300 {
    self.account.name = @"foo";
}
- (void)testExample301 {
    self.account.name = @"foo";
}
- (void)testExample302 {
    self.account.name = @"foo";
}
- (void)testExample303 {
    self.account.name = @"foo";
}
- (void)testExample304 {
    self.account.name = @"foo";
}
- (void)testExample305 {
    self.account.name = @"foo";
}
- (void)testExample306 {
    self.account.name = @"foo";
}
- (void)testExample307 {
    self.account.name = @"foo";
}
- (void)testExample308 {
    self.account.name = @"foo";
}
- (void)testExample309 {
    self.account.name = @"foo";
}
- (void)testExample310 {
    self.account.name = @"foo";
}
- (void)testExample311 {
    self.account.name = @"foo";
}
- (void)testExample312 {
    self.account.name = @"foo";
}
- (void)testExample313 {
    self.account.name = @"foo";
}
- (void)testExample314 {
    self.account.name = @"foo";
}
- (void)testExample315 {
    self.account.name = @"foo";
}
- (void)testExample316 {
    self.account.name = @"foo";
}
- (void)testExample317 {
    self.account.name = @"foo";
}
- (void)testExample318 {
    self.account.name = @"foo";
}
- (void)testExample319 {
    self.account.name = @"foo";
}
- (void)testExample320 {
    self.account.name = @"foo";
}
- (void)testExample321 {
    self.account.name = @"foo";
}
- (void)testExample322 {
    self.account.name = @"foo";
}
- (void)testExample323 {
    self.account.name = @"foo";
}
- (void)testExample324 {
    self.account.name = @"foo";
}
- (void)testExample325 {
    self.account.name = @"foo";
}
- (void)testExample326 {
    self.account.name = @"foo";
}
- (void)testExample327 {
    self.account.name = @"foo";
}
- (void)testExample328 {
    self.account.name = @"foo";
}
- (void)testExample329 {
    self.account.name = @"foo";
}
- (void)testExample330 {
    self.account.name = @"foo";
}
- (void)testExample331 {
    self.account.name = @"foo";
}
- (void)testExample332 {
    self.account.name = @"foo";
}
- (void)testExample333 {
    self.account.name = @"foo";
}
- (void)testExample334 {
    self.account.name = @"foo";
}
- (void)testExample335 {
    self.account.name = @"foo";
}
- (void)testExample336 {
    self.account.name = @"foo";
}
- (void)testExample337 {
    self.account.name = @"foo";
}
- (void)testExample338 {
    self.account.name = @"foo";
}
- (void)testExample339 {
    self.account.name = @"foo";
}
- (void)testExample340 {
    self.account.name = @"foo";
}
- (void)testExample341 {
    self.account.name = @"foo";
}
- (void)testExample342 {
    self.account.name = @"foo";
}
- (void)testExample343 {
    self.account.name = @"foo";
}
- (void)testExample344 {
    self.account.name = @"foo";
}
- (void)testExample345 {
    self.account.name = @"foo";
}
- (void)testExample346 {
    self.account.name = @"foo";
}
- (void)testExample347 {
    self.account.name = @"foo";
}
- (void)testExample348 {
    self.account.name = @"foo";
}
- (void)testExample349 {
    self.account.name = @"foo";
}
- (void)testExample350 {
    self.account.name = @"foo";
}
- (void)testExample351 {
    self.account.name = @"foo";
}
- (void)testExample352 {
    self.account.name = @"foo";
}
- (void)testExample353 {
    self.account.name = @"foo";
}
- (void)testExample354 {
    self.account.name = @"foo";
}
- (void)testExample355 {
    self.account.name = @"foo";
}
- (void)testExample356 {
    self.account.name = @"foo";
}
- (void)testExample357 {
    self.account.name = @"foo";
}
- (void)testExample358 {
    self.account.name = @"foo";
}
- (void)testExample359 {
    self.account.name = @"foo";
}
- (void)testExample360 {
    self.account.name = @"foo";
}
- (void)testExample361 {
    self.account.name = @"foo";
}
- (void)testExample362 {
    self.account.name = @"foo";
}
- (void)testExample363 {
    self.account.name = @"foo";
}
- (void)testExample364 {
    self.account.name = @"foo";
}
- (void)testExample365 {
    self.account.name = @"foo";
}
- (void)testExample366 {
    self.account.name = @"foo";
}
- (void)testExample367 {
    self.account.name = @"foo";
}
- (void)testExample368 {
    self.account.name = @"foo";
}
- (void)testExample369 {
    self.account.name = @"foo";
}
- (void)testExample370 {
    self.account.name = @"foo";
}
- (void)testExample371 {
    self.account.name = @"foo";
}
- (void)testExample372 {
    self.account.name = @"foo";
}
- (void)testExample373 {
    self.account.name = @"foo";
}
- (void)testExample374 {
    self.account.name = @"foo";
}
- (void)testExample375 {
    self.account.name = @"foo";
}
- (void)testExample376 {
    self.account.name = @"foo";
}
- (void)testExample377 {
    self.account.name = @"foo";
}
- (void)testExample378 {
    self.account.name = @"foo";
}
- (void)testExample379 {
    self.account.name = @"foo";
}
- (void)testExample380 {
    self.account.name = @"foo";
}
- (void)testExample381 {
    self.account.name = @"foo";
}
- (void)testExample382 {
    self.account.name = @"foo";
}
- (void)testExample383 {
    self.account.name = @"foo";
}
- (void)testExample384 {
    self.account.name = @"foo";
}
- (void)testExample385 {
    self.account.name = @"foo";
}
- (void)testExample386 {
    self.account.name = @"foo";
}
- (void)testExample387 {
    self.account.name = @"foo";
}
- (void)testExample388 {
    self.account.name = @"foo";
}
- (void)testExample389 {
    self.account.name = @"foo";
}
- (void)testExample390 {
    self.account.name = @"foo";
}
- (void)testExample391 {
    self.account.name = @"foo";
}
- (void)testExample392 {
    self.account.name = @"foo";
}
- (void)testExample393 {
    self.account.name = @"foo";
}
- (void)testExample394 {
    self.account.name = @"foo";
}
- (void)testExample395 {
    self.account.name = @"foo";
}
- (void)testExample396 {
    self.account.name = @"foo";
}
- (void)testExample397 {
    self.account.name = @"foo";
}
- (void)testExample398 {
    self.account.name = @"foo";
}
- (void)testExample399 {
    self.account.name = @"foo";
}
- (void)testExample400 {
    self.account.name = @"foo";
}
- (void)testExample401 {
    self.account.name = @"foo";
}
- (void)testExample402 {
    self.account.name = @"foo";
}
- (void)testExample403 {
    self.account.name = @"foo";
}
- (void)testExample404 {
    self.account.name = @"foo";
}
- (void)testExample405 {
    self.account.name = @"foo";
}
- (void)testExample406 {
    self.account.name = @"foo";
}
- (void)testExample407 {
    self.account.name = @"foo";
}
- (void)testExample408 {
    self.account.name = @"foo";
}
- (void)testExample409 {
    self.account.name = @"foo";
}
- (void)testExample410 {
    self.account.name = @"foo";
}
- (void)testExample411 {
    self.account.name = @"foo";
}
- (void)testExample412 {
    self.account.name = @"foo";
}
- (void)testExample413 {
    self.account.name = @"foo";
}
- (void)testExample414 {
    self.account.name = @"foo";
}
- (void)testExample415 {
    self.account.name = @"foo";
}
- (void)testExample416 {
    self.account.name = @"foo";
}
- (void)testExample417 {
    self.account.name = @"foo";
}
- (void)testExample418 {
    self.account.name = @"foo";
}
- (void)testExample419 {
    self.account.name = @"foo";
}
- (void)testExample420 {
    self.account.name = @"foo";
}
- (void)testExample421 {
    self.account.name = @"foo";
}
- (void)testExample422 {
    self.account.name = @"foo";
}
- (void)testExample423 {
    self.account.name = @"foo";
}
- (void)testExample424 {
    self.account.name = @"foo";
}
- (void)testExample425 {
    self.account.name = @"foo";
}
- (void)testExample426 {
    self.account.name = @"foo";
}
- (void)testExample427 {
    self.account.name = @"foo";
}
- (void)testExample428 {
    self.account.name = @"foo";
}
- (void)testExample429 {
    self.account.name = @"foo";
}
- (void)testExample430 {
    self.account.name = @"foo";
}
- (void)testExample431 {
    self.account.name = @"foo";
}
- (void)testExample432 {
    self.account.name = @"foo";
}
- (void)testExample433 {
    self.account.name = @"foo";
}
- (void)testExample434 {
    self.account.name = @"foo";
}
- (void)testExample435 {
    self.account.name = @"foo";
}
- (void)testExample436 {
    self.account.name = @"foo";
}
- (void)testExample437 {
    self.account.name = @"foo";
}
- (void)testExample438 {
    self.account.name = @"foo";
}
- (void)testExample439 {
    self.account.name = @"foo";
}
- (void)testExample440 {
    self.account.name = @"foo";
}
- (void)testExample441 {
    self.account.name = @"foo";
}
- (void)testExample442 {
    self.account.name = @"foo";
}
- (void)testExample443 {
    self.account.name = @"foo";
}
- (void)testExample444 {
    self.account.name = @"foo";
}
- (void)testExample445 {
    self.account.name = @"foo";
}
- (void)testExample446 {
    self.account.name = @"foo";
}
- (void)testExample447 {
    self.account.name = @"foo";
}
- (void)testExample448 {
    self.account.name = @"foo";
}
- (void)testExample449 {
    self.account.name = @"foo";
}
- (void)testExample450 {
    self.account.name = @"foo";
}
- (void)testExample451 {
    self.account.name = @"foo";
}
- (void)testExample452 {
    self.account.name = @"foo";
}
- (void)testExample453 {
    self.account.name = @"foo";
}
- (void)testExample454 {
    self.account.name = @"foo";
}
- (void)testExample455 {
    self.account.name = @"foo";
}
- (void)testExample456 {
    self.account.name = @"foo";
}
- (void)testExample457 {
    self.account.name = @"foo";
}
- (void)testExample458 {
    self.account.name = @"foo";
}
- (void)testExample459 {
    self.account.name = @"foo";
}
- (void)testExample460 {
    self.account.name = @"foo";
}
- (void)testExample461 {
    self.account.name = @"foo";
}
- (void)testExample462 {
    self.account.name = @"foo";
}
- (void)testExample463 {
    self.account.name = @"foo";
}
- (void)testExample464 {
    self.account.name = @"foo";
}
- (void)testExample465 {
    self.account.name = @"foo";
}
- (void)testExample466 {
    self.account.name = @"foo";
}
- (void)testExample467 {
    self.account.name = @"foo";
}
- (void)testExample468 {
    self.account.name = @"foo";
}
- (void)testExample469 {
    self.account.name = @"foo";
}
- (void)testExample470 {
    self.account.name = @"foo";
}
- (void)testExample471 {
    self.account.name = @"foo";
}
- (void)testExample472 {
    self.account.name = @"foo";
}
- (void)testExample473 {
    self.account.name = @"foo";
}
- (void)testExample474 {
    self.account.name = @"foo";
}
- (void)testExample475 {
    self.account.name = @"foo";
}
- (void)testExample476 {
    self.account.name = @"foo";
}
- (void)testExample477 {
    self.account.name = @"foo";
}
- (void)testExample478 {
    self.account.name = @"foo";
}
- (void)testExample479 {
    self.account.name = @"foo";
}
- (void)testExample480 {
    self.account.name = @"foo";
}
- (void)testExample481 {
    self.account.name = @"foo";
}
- (void)testExample482 {
    self.account.name = @"foo";
}
- (void)testExample483 {
    self.account.name = @"foo";
}
- (void)testExample484 {
    self.account.name = @"foo";
}
- (void)testExample485 {
    self.account.name = @"foo";
}
- (void)testExample486 {
    self.account.name = @"foo";
}
- (void)testExample487 {
    self.account.name = @"foo";
}
- (void)testExample488 {
    self.account.name = @"foo";
}
- (void)testExample489 {
    self.account.name = @"foo";
}
- (void)testExample490 {
    self.account.name = @"foo";
}
- (void)testExample491 {
    self.account.name = @"foo";
}
- (void)testExample492 {
    self.account.name = @"foo";
}
- (void)testExample493 {
    self.account.name = @"foo";
}
- (void)testExample494 {
    self.account.name = @"foo";
}
- (void)testExample495 {
    self.account.name = @"foo";
}
- (void)testExample496 {
    self.account.name = @"foo";
}
- (void)testExample497 {
    self.account.name = @"foo";
}
- (void)testExample498 {
    self.account.name = @"foo";
}
- (void)testExample499 {
    self.account.name = @"foo";
}
@end
