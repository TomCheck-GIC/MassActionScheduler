@IsTest
private class MAS_CFE_SchedulerTest {
    @IsTest
    static void schedulerRunsBatchWhenActive() {
        insert new Account(Name = 'Sched Acct');
        MAS_CFE_Configuration__c cfg = new MAS_CFE_Configuration__c(
            Name = 'Sched Config',
            Developer_Name__c = 'sched_config',
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
        MAS_CFE_SampleAction.capturedNames.clear();

        Test.startTest();
        new MAS_CFE_Scheduler(cfg.Id).execute(null);
        Test.stopTest();

        Assert.isTrue(!MAS_CFE_SampleAction.capturedNames.isEmpty(), 'Scheduler launched the batch and target ran');
    }

    @IsTest
    static void inactiveConfigDoesNotRun() {
        insert new Account(Name = 'Inactive Acct');
        MAS_CFE_Configuration__c cfg = new MAS_CFE_Configuration__c(
            Name = 'Inactive Config',
            Developer_Name__c = 'inactive_config',
            Active__c = false,
            Batch_Size__c = 50,
            Source_SOQL_Query__c = 'SELECT Id, Name FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = 'MAS_CFE_SampleAction'
        );
        insert cfg;
        MAS_CFE_SampleAction.capturedNames.clear();

        Test.startTest();
        new MAS_CFE_Scheduler(cfg.Id).execute(null);
        Test.stopTest();

        Assert.isTrue(MAS_CFE_SampleAction.capturedNames.isEmpty(), 'Inactive config should not run');
    }
}
