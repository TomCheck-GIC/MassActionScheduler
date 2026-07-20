@IsTest
private class MAS_ConfigControllerTest {
    private static MAS_Configuration__c makeConfig() {
        MAS_Configuration__c cfg = new MAS_Configuration__c(
            Name = 'Ctrl Config',
            Developer_Name__c = 'ctrl_config',
            Active__c = true,
            Batch_Size__c = 50,
            Source_SOQL_Query__c = 'SELECT Id, Name FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = 'MAS_SampleAction'
        );
        insert cfg;
        return cfg;
    }

    @IsTest
    static void discoveryMethods() {
        insert new Account(Name = 'Preview Acct');
        MAS_Configuration__c cfg = makeConfig();

        Test.startTest();
        List<MAS_ConfigController.FlowOption> flows = MAS_ConfigController.getActiveFlows();
        List<MAS_ConfigController.InputParam> inputs = MAS_ConfigController.getActionInputs('Apex', 'MAS_SampleAction');
        MAS_ConfigController.PreviewResult preview = MAS_ConfigController.previewSource('SELECT Id, Name FROM Account');
        Test.stopTest();

        System.assertNotEquals(null, flows, 'Flow list returned (may be empty)');
        System.assertNotEquals(null, inputs, 'Inputs returned');
        System.assert(inputs.size() >= 1, 'Sample action exposes input parameters');
        System.assert(preview.columns.contains('Id') && preview.columns.contains('Name'), 'Columns parsed');
        System.assert(preview.rows.size() >= 1, 'Preview returned rows');
    }

    @IsTest
    static void runNowStartsBatch() {
        insert new Account(Name = 'Run Acct');
        MAS_Configuration__c cfg = makeConfig();
        insert new MAS_Field_Mapping__c(
            Configuration__c = cfg.Id, Source_Field_Name__c = 'Name',
            Target_Parameter_Name__c = 'recordName', Is_Literal__c = false
        );

        Test.startTest();
        Id jobId = MAS_ConfigController.runNow(cfg.Id);
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Batch job id returned');
        List<MAS_Log__c> logs = [SELECT Id FROM MAS_Log__c WHERE Configuration__c = :cfg.Id];
        System.assert(!logs.isEmpty(), 'A run log was created');
    }

    @IsTest
    static void scheduleAndUnschedule() {
        MAS_Configuration__c cfg = makeConfig();

        Test.startTest();
        String jobId = MAS_ConfigController.saveSchedule(cfg.Id, '0 0 6 * * ?');
        System.assert(String.isNotBlank(jobId), 'Schedule returns a job id');
        MAS_Configuration__c scheduled = [SELECT Scheduled_Job_Id__c, Schedule_Type__c FROM MAS_Configuration__c WHERE Id = :cfg.Id];
        System.assertEquals(jobId, scheduled.Scheduled_Job_Id__c, 'Job id stored');
        System.assertEquals('Scheduled', scheduled.Schedule_Type__c, 'Schedule type set');

        MAS_ConfigController.unschedule(cfg.Id);
        Test.stopTest();

        MAS_Configuration__c cleared = [SELECT Scheduled_Job_Id__c FROM MAS_Configuration__c WHERE Id = :cfg.Id];
        System.assertEquals(null, cleared.Scheduled_Job_Id__c, 'Job id cleared after unschedule');
    }

    @IsTest
    static void crudHelpers() {
        MAS_Configuration__c cfg = makeConfig();

        MAS_Configuration__c fetched = MAS_ConfigController.getConfig(cfg.Id);
        System.assertEquals(cfg.Id, fetched.Id, 'getConfig');

        fetched.Description__c = 'Updated';
        Id savedId = MAS_ConfigController.saveConfig(fetched);
        System.assertEquals(cfg.Id, savedId, 'saveConfig upserts');

        List<MAS_Field_Mapping__c> mappings = new List<MAS_Field_Mapping__c>{
            new MAS_Field_Mapping__c(Source_Field_Name__c = 'Name', Target_Parameter_Name__c = 'recordName', Is_Literal__c = false),
            new MAS_Field_Mapping__c(Source_Field_Name__c = 'Id', Target_Parameter_Name__c = 'recordId', Is_Literal__c = false)
        };
        MAS_ConfigController.saveMappings(cfg.Id, mappings);
        System.assertEquals(2, MAS_ConfigController.getMappings(cfg.Id).size(), 'Mappings saved');

        // Replace with a single mapping
        MAS_ConfigController.saveMappings(cfg.Id, new List<MAS_Field_Mapping__c>{
            new MAS_Field_Mapping__c(Source_Field_Name__c = 'Name', Target_Parameter_Name__c = 'recordName', Is_Literal__c = false)
        });
        System.assertEquals(1, MAS_ConfigController.getMappings(cfg.Id).size(), 'Mappings replaced');

        System.assertNotEquals(null, MAS_ConfigController.getLogs(cfg.Id), 'getLogs returns a list');
    }
}
