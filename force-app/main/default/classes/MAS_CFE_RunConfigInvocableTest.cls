@IsTest
private class MAS_CFE_RunConfigInvocableTest {
    private static MAS_CFE_Configuration__c makeConfig(String devName) {
        MAS_CFE_Configuration__c cfg = new MAS_CFE_Configuration__c(
            Name = 'Inv Config ' + devName,
            Developer_Name__c = devName,
            Active__c = true,
            Batch_Size__c = 50,
            Source_SOQL_Query__c = 'SELECT Id, Name FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = 'MAS_CFE_SampleAction'
        );
        insert cfg;
        insert new MAS_CFE_Field_Mapping__c(
            Configuration__c = cfg.Id, Source_Field_Name__c = 'Name',
            Target_Parameter_Name__c = 'recordName', Is_Literal__c = false
        );
        return cfg;
    }

    @IsTest
    static void runsByConfigId() {
        insert new Account(Name = 'Inv Acct');
        MAS_CFE_Configuration__c cfg = makeConfig('inv_by_id');

        MAS_CFE_RunConfigInvocable.Request req = new MAS_CFE_RunConfigInvocable.Request();
        req.configId = cfg.Id;

        Test.startTest();
        List<MAS_CFE_RunConfigInvocable.Response> resp = MAS_CFE_RunConfigInvocable.run(new List<MAS_CFE_RunConfigInvocable.Request>{ req });
        Test.stopTest();

        Assert.areEqual(1, resp.size(), 'One response');
        Assert.areNotEqual(null, resp[0].jobId, 'Batch job launched');
    }

    @IsTest
    static void runsByDeveloperNameWithOverride() {
        insert new Account(Name = 'Inv Acct 2');
        MAS_CFE_Configuration__c cfg = makeConfig('inv_by_name');

        MAS_CFE_RunConfigInvocable.Request req = new MAS_CFE_RunConfigInvocable.Request();
        req.developerName = 'inv_by_name';
        req.batchSize = 10;

        Test.startTest();
        List<MAS_CFE_RunConfigInvocable.Response> resp = MAS_CFE_RunConfigInvocable.run(new List<MAS_CFE_RunConfigInvocable.Request>{ req });
        Test.stopTest();

        Assert.areNotEqual(null, resp[0].jobId, 'Batch job launched by developer name');
    }

    @IsTest
    static void unknownConfigReturnsNullJob() {
        MAS_CFE_RunConfigInvocable.Request req = new MAS_CFE_RunConfigInvocable.Request();
        req.developerName = 'does_not_exist';

        Test.startTest();
        List<MAS_CFE_RunConfigInvocable.Response> resp = MAS_CFE_RunConfigInvocable.run(new List<MAS_CFE_RunConfigInvocable.Request>{ req });
        Test.stopTest();

        Assert.areEqual(1, resp.size(), 'Response returned');
        Assert.areEqual(null, resp[0].jobId, 'No job for unknown config');
        Assert.isTrue(String.isNotBlank(resp[0].errorMessage), 'Response should explain why no job was launched');
    }

    @IsTest
    static void requestsBeyondAsyncCallLimitDegradeGracefully() {
        // A Flow could call this action once per record in a bulk update, easily
        // exceeding the transaction's async-call budget. Rather than actually
        // launching enough real batch jobs to hit the limit (which would also
        // collide with the org-wide flex queue capacity), simulate the budget
        // already being used up via the test-only override.
        insert new Account(Name = 'Inv Acct Bulk');
        MAS_CFE_Configuration__c cfg = makeConfig('inv_over_limit');
        MAS_CFE_RunConfigInvocable.testAsyncCallsAlreadyUsed = Limits.getLimitAsyncCalls();

        MAS_CFE_RunConfigInvocable.Request req = new MAS_CFE_RunConfigInvocable.Request();
        req.configId = cfg.Id;

        Test.startTest();
        List<MAS_CFE_RunConfigInvocable.Response> resp = MAS_CFE_RunConfigInvocable.run(new List<MAS_CFE_RunConfigInvocable.Request>{ req });
        Test.stopTest();

        Assert.areEqual(1, resp.size(), 'One response');
        Assert.areEqual(null, resp[0].jobId, 'No job should launch once the async-call budget is used up');
        Assert.isTrue(String.isNotBlank(resp[0].errorMessage), 'Skipped requests should explain why');
    }
}
