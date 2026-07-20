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

        System.assertEquals(5, MAS_SampleAction.capturedNames.size(), 'All records should reach the target');

        MAS_Log__c summary = [
            SELECT Processed_Records__c, Failed_Records__c, Batch_Success_Percentage__c, Message_Type__c
            FROM MAS_Log__c WHERE Configuration__c = :cfg.Id AND Parent_Log__c = null
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        System.assertEquals(5, summary.Processed_Records__c, 'Processed count');
        System.assertEquals(0, summary.Failed_Records__c, 'Failed count');

        MAS_Configuration__c after = [SELECT Last_Run_Status__c, Last_Run_Completed_Date__c FROM MAS_Configuration__c WHERE Id = :cfg.Id];
        System.assertEquals('Success', after.Last_Run_Status__c, 'Status should be Success');
        System.assertNotEquals(null, after.Last_Run_Completed_Date__c, 'Completed date set');
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

        System.assertEquals(2, MAS_SampleAction.capturedNames.size(), 'Both records invoked');
        for (String v : MAS_SampleAction.capturedNames) {
            System.assertEquals('CONST', v, 'Literal value passed through');
        }
    }

    @IsTest
    static void invalidTargetIsLoggedAsError() {
        seedAccounts(2);
        MAS_Configuration__c cfg = makeConfig('MAS_NoSuchAction_ZZZ');

        Test.startTest();
        Database.executeBatch(new MAS_BatchRunner(cfg.Id), 200);
        Test.stopTest();

        List<MAS_Log__c> errors = [SELECT Id FROM MAS_Log__c WHERE Configuration__c = :cfg.Id AND Message_Type__c = 'Error'];
        System.assert(!errors.isEmpty(), 'An error log should be written for the invalid target');

        MAS_Configuration__c after = [SELECT Last_Run_Status__c FROM MAS_Configuration__c WHERE Id = :cfg.Id];
        System.assertEquals('Failed', after.Last_Run_Status__c, 'Status should be Failed when nothing processed');
    }
}
