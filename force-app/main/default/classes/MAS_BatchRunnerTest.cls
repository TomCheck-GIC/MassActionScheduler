@IsTest
private class MAS_BatchRunnerTest {
    private static MAS_Configuration__c makeConfig(String targetName) {
        MAS_Configuration__c cfg = new MAS_Configuration__c(
            Name = 'Test Config',
            Developer_Name__c = 'test_config_' + targetName,
            Active__c = true,
            Batch_Size__c = 200,
            Source_SOQL_Query__c = 'SELECT Id, Name FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = targetName
        );
        insert cfg;
        return cfg;
    }

    private static void seedAccounts(Integer count) {
        List<Account> accts = new List<Account>();
        for (Integer i = 0; i < count; i++) {
            accts.add(new Account(Name = 'Acct ' + i));
        }
        insert accts;
    }

    @IsTest
    static void runsApexTargetAndLogsSuccess() {
        seedAccounts(5);
        MAS_Configuration__c cfg = makeConfig('MAS_SampleAction');
        insert new MAS_Field_Mapping__c(
            Configuration__c = cfg.Id,
            Source_Field_Name__c = 'Name',
            Target_Parameter_Name__c = 'recordName',
            Is_Literal__c = false
        );
        MAS_SampleAction.capturedNames.clear();

        Test.startTest();
        Database.executeBatch(new MAS_BatchRunner(cfg.Id), 200);
        Test.stopTest();

        Assert.areEqual(5, MAS_SampleAction.capturedNames.size(), 'All records should reach the target');

        MAS_Log__c summary = [
            SELECT Processed_Records__c, Failed_Records__c, Batch_Success_Percentage__c, Message_Type__c
            FROM MAS_Log__c WHERE Configuration__c = :cfg.Id AND Parent_Log__c = null
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        Assert.areEqual(5, summary.Processed_Records__c, 'Processed count');
        Assert.areEqual(0, summary.Failed_Records__c, 'Failed count');

        MAS_Configuration__c after = [SELECT Last_Run_Status__c, Last_Run_Completed_Date__c FROM MAS_Configuration__c WHERE Id = :cfg.Id];
        Assert.areEqual('Success', after.Last_Run_Status__c, 'Status should be Success');
        Assert.areNotEqual(null, after.Last_Run_Completed_Date__c, 'Completed date set');

        // A clean chunk (no failures) should still leave a browsable per-record
        // detail log, not just an aggregate count.
        MAS_Log__c chunkLog = [
            SELECT Message_Type__c, Long_Message__c, Total_Records__c, Processed_Records__c,
                   Failed_Records__c, Batch_Success_Percentage__c
            FROM MAS_Log__c WHERE Configuration__c = :cfg.Id AND Parent_Log__c = :summary.Id
            LIMIT 1
        ];
        Assert.areEqual('Success', chunkLog.Message_Type__c, 'Clean chunk should log as Success');
        Assert.areEqual(5, chunkLog.Total_Records__c, 'Child log records its own batch total');
        Assert.areEqual(5, chunkLog.Processed_Records__c, 'Child log records its own processed count');
        Assert.areEqual(0, chunkLog.Failed_Records__c, 'Child log records its own failed count');
        Assert.areEqual(100, chunkLog.Batch_Success_Percentage__c, 'Child log records its own success percentage');
        List<Account> accts = [SELECT Id FROM Account];
        for (Account a : accts) {
            Assert.isTrue(chunkLog.Long_Message__c.contains(a.Id + ': OK'), 'Each processed record Id should appear in the chunk detail');
        }
    }

    @IsTest
    static void supportsLiteralMapping() {
        seedAccounts(2);
        MAS_Configuration__c cfg = makeConfig('MAS_SampleAction');
        insert new MAS_Field_Mapping__c(
            Configuration__c = cfg.Id,
            Source_Field_Name__c = 'CONST',
            Target_Parameter_Name__c = 'recordName',
            Is_Literal__c = true
        );
        MAS_SampleAction.capturedNames.clear();

        Test.startTest();
        Database.executeBatch(new MAS_BatchRunner(cfg.Id), 200);
        Test.stopTest();

        Assert.areEqual(2, MAS_SampleAction.capturedNames.size(), 'Both records invoked');
        for (String v : MAS_SampleAction.capturedNames) {
            Assert.areEqual('CONST', v, 'Literal value passed through');
        }
    }

    @IsTest
    static void runsFlowTargetWithIdMapping() {
        // Regression test: Flow variables are always Text/Number/etc. (Flow has
        // no "Id" type), so an Id-valued source column mapped to a Flow input
        // must be coerced to String or the invocation fails with
        // "can't accept values of type ID."
        seedAccounts(3);
        MAS_Configuration__c cfg = makeConfig('MAS_SampleAction');
        cfg.Target_Type__c = 'Flow';
        cfg.Target_Action_Name__c = 'MAS_SampleFlow';
        update cfg;
        insert new List<MAS_Field_Mapping__c>{
            new MAS_Field_Mapping__c(
                Configuration__c = cfg.Id, Source_Field_Name__c = 'Name',
                Target_Parameter_Name__c = 'recordName', Is_Literal__c = false
            ),
            new MAS_Field_Mapping__c(
                Configuration__c = cfg.Id, Source_Field_Name__c = 'Id',
                Target_Parameter_Name__c = 'recordId', Is_Literal__c = false
            )
        };

        Test.startTest();
        Database.executeBatch(new MAS_BatchRunner(cfg.Id), 200);
        Test.stopTest();

        MAS_Log__c summary = [
            SELECT Processed_Records__c, Failed_Records__c, Message_Type__c
            FROM MAS_Log__c WHERE Configuration__c = :cfg.Id AND Parent_Log__c = null
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        Assert.areEqual(3, summary.Processed_Records__c, 'Flow target should accept the coerced Id as a String');
        Assert.areEqual(0, summary.Failed_Records__c, 'No failures once Id is coerced to String');
        Assert.areEqual('Success', summary.Message_Type__c, 'Run should succeed');
    }

    @IsTest
    static void coerceForTargetConvertsIdToStringForNonIdParams() {
        MAS_BatchRunner runner = new MAS_BatchRunner(null);
        Id sampleId = [SELECT Id FROM Account LIMIT 1]?.Id;
        if (sampleId == null) {
            insert new Account(Name = 'Coerce Test');
            sampleId = [SELECT Id FROM Account LIMIT 1].Id;
        }
        Object coerced = runner.coerceForTarget(sampleId, 'STRING');
        Assert.isTrue(coerced instanceof String, 'Id should be coerced to String for a String-typed parameter');
        Assert.areEqual(String.valueOf(sampleId), coerced, 'Coerced value should match the Id string form');

        Object untouchedId = runner.coerceForTarget(sampleId, 'ID');
        Assert.areEqual(sampleId, untouchedId, 'Id should stay an Id for an ID-typed parameter');

        Object untouchedOther = runner.coerceForTarget('plain string', 'STRING');
        Assert.areEqual('plain string', untouchedOther, 'Non-Id values pass through unchanged');
    }

    @IsTest
    static void invalidTargetIsLoggedAsError() {
        seedAccounts(2);
        MAS_Configuration__c cfg = makeConfig('MAS_NoSuchAction_ZZZ');

        Test.startTest();
        Database.executeBatch(new MAS_BatchRunner(cfg.Id), 200);
        Test.stopTest();

        List<MAS_Log__c> errors = [
            SELECT Id, Long_Message__c, Total_Records__c, Processed_Records__c, Failed_Records__c, Batch_Success_Percentage__c
            FROM MAS_Log__c WHERE Configuration__c = :cfg.Id AND Message_Type__c = 'Error'
        ];
        Assert.isTrue(!errors.isEmpty(), 'An error log should be written for the invalid target');
        Assert.areEqual(2, errors[0].Total_Records__c, 'Failed chunk still records its own batch total');
        Assert.areEqual(0, errors[0].Processed_Records__c, 'Failed chunk records zero processed');
        Assert.areEqual(2, errors[0].Failed_Records__c, 'Failed chunk records every record as failed');
        Assert.areEqual(0, errors[0].Batch_Success_Percentage__c, 'Failed chunk records a zero success percentage');

        List<Account> accts = [SELECT Id FROM Account];
        for (Account a : accts) {
            Assert.isTrue(errors[0].Long_Message__c.contains(a.Id + ': FAILED'), 'Each failed record Id should appear in the chunk detail');
        }

        MAS_Configuration__c after = [SELECT Last_Run_Status__c FROM MAS_Configuration__c WHERE Id = :cfg.Id];
        Assert.areEqual('Failed', after.Last_Run_Status__c, 'Status should be Failed when nothing processed');
    }

    @IsTest
    static void bulkRunProcessesFullSizeChunk() {
        // Apex test context permits only a single execute() call, and the query
        // locator's record count cannot exceed the scope size in that context
        // (Database.executeBatch throws if it would need more than one chunk).
        // Seeding a full 200-record chunk - the maximum allowed batch scope -
        // is the largest bulk case a unit test can exercise for a Batchable class.
        seedAccounts(200);
        MAS_Configuration__c cfg = makeConfig('MAS_SampleAction');
        insert new MAS_Field_Mapping__c(
            Configuration__c = cfg.Id,
            Source_Field_Name__c = 'Name',
            Target_Parameter_Name__c = 'recordName',
            Is_Literal__c = false
        );
        MAS_SampleAction.capturedNames.clear();

        Test.startTest();
        Database.executeBatch(new MAS_BatchRunner(cfg.Id), 200);
        Test.stopTest();

        Assert.areEqual(200, MAS_SampleAction.capturedNames.size(), 'Test context runs a single 200-record chunk');

        MAS_Log__c summary = [
            SELECT Total_Records__c, Processed_Records__c, Failed_Records__c, Total_Batches__c, Failed_Batches__c
            FROM MAS_Log__c WHERE Configuration__c = :cfg.Id AND Parent_Log__c = null
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        Assert.areEqual(200, summary.Total_Records__c, 'Total records reflects the single processed chunk');
        Assert.areEqual(200, summary.Processed_Records__c, 'All 200 records in the chunk should process');
        Assert.areEqual(0, summary.Failed_Records__c, 'No failures expected');
        Assert.areEqual(1, summary.Total_Batches__c, 'Only one execute() chunk runs in test context');
        Assert.areEqual(0, summary.Failed_Batches__c, 'The chunk should not be marked failed');
    }
}
