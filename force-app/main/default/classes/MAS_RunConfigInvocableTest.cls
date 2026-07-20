@IsTest
private class MAS_RunConfigInvocableTest {
    private static MAS_Configuration__c makeConfig(String devName) {
        MAS_Configuration__c cfg = new MAS_Configuration__c(
            Name = 'Inv Config ' + devName,
            Developer_Name__c = devName,
            Active__c = true,
            Batch_Size__c = 50,
            Source_SOQL_Query__c = 'SELECT Id, Name FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = 'MAS_SampleAction'
        );
        insert cfg;
        insert new MAS_Field_Mapping__c(
            Configuration__c = cfg.Id, Source_Field_Name__c = 'Name',
            Target_Parameter_Name__c = 'recordName', Is_Literal__c = false
        );
        return cfg;
    }

    @IsTest
    static void runsByConfigId() {
        insert new Account(Name = 'Inv Acct');
        MAS_Configuration__c cfg = makeConfig('inv_by_id');

        MAS_RunConfigInvocable.Request req = new MAS_RunConfigInvocable.Request();
        req.configId = cfg.Id;

        Test.startTest();
        List<MAS_RunConfigInvocable.Response> resp = MAS_RunConfigInvocable.run(new List<MAS_RunConfigInvocable.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, resp.size(), 'One response');
        System.assertNotEquals(null, resp[0].jobId, 'Batch job launched');
    }

    @IsTest
    static void runsByDeveloperNameWithOverride() {
        insert new Account(Name = 'Inv Acct 2');
        MAS_Configuration__c cfg = makeConfig('inv_by_name');

        MAS_RunConfigInvocable.Request req = new MAS_RunConfigInvocable.Request();
        req.developerName = 'inv_by_name';
        req.batchSize = 10;

        Test.startTest();
        List<MAS_RunConfigInvocable.Response> resp = MAS_RunConfigInvocable.run(new List<MAS_RunConfigInvocable.Request>{ req });
        Test.stopTest();

        System.assertNotEquals(null, resp[0].jobId, 'Batch job launched by developer name');
    }

    @IsTest
    static void unknownConfigReturnsNullJob() {
        MAS_RunConfigInvocable.Request req = new MAS_RunConfigInvocable.Request();
        req.developerName = 'does_not_exist';

        Test.startTest();
        List<MAS_RunConfigInvocable.Response> resp = MAS_RunConfigInvocable.run(new List<MAS_RunConfigInvocable.Request>{ req });
        Test.stopTest();

        System.assertEquals(1, resp.size(), 'Response returned');
        System.assertEquals(null, resp[0].jobId, 'No job for unknown config');
    }
}
