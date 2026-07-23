@IsTest
private class MAS_GIC_ConfigControllerTest {
    private static MAS_GIC_Configuration__c makeConfig() {
        MAS_GIC_Configuration__c cfg = new MAS_GIC_Configuration__c(
            Name = 'Ctrl Config',
            Developer_Name__c = 'ctrl_config',
            Active__c = true,
            Batch_Size__c = 50,
            Source_SOQL_Query__c = 'SELECT Id, Name FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = 'MAS_GIC_SampleAction'
        );
        insert cfg;
        return cfg;
    }

    @IsTest
    static void discoveryMethods() {
        insert new Account(Name = 'Preview Acct');
        MAS_GIC_Configuration__c cfg = makeConfig();

        Test.startTest();
        List<MAS_GIC_ConfigController.FlowOption> flows = MAS_GIC_ConfigController.getActiveFlows();
        List<MAS_GIC_ConfigController.InputParam> inputs = MAS_GIC_ConfigController.getActionInputs('Apex', 'MAS_GIC_SampleAction');
        MAS_GIC_ConfigController.PreviewResult preview = MAS_GIC_ConfigController.previewSource('SELECT Id, Name FROM Account');
        Test.stopTest();

        Assert.areNotEqual(null, flows, 'Flow list returned (may be empty)');
        Assert.areNotEqual(null, inputs, 'Inputs returned');
        Assert.isTrue(inputs.size() >= 1, 'Sample action exposes input parameters');
        Assert.isTrue(preview.columns.contains('Id') && preview.columns.contains('Name'), 'Columns parsed');
        Assert.isTrue(preview.rows.size() >= 1, 'Preview returned rows');
    }

    @IsTest
    static void getInvocableApexClassesListsSampleActionButExcludesTheLauncher() {
        Test.startTest();
        List<MAS_GIC_ConfigController.ApexActionOption> options = MAS_GIC_ConfigController.getInvocableApexClasses();
        Test.stopTest();

        Set<String> apiNames = new Set<String>();
        for (MAS_GIC_ConfigController.ApexActionOption o : options) {
            apiNames.add(o.apiName);
        }
        Assert.isTrue(apiNames.contains('MAS_GIC_SampleAction'), 'A real @InvocableMethod class should be listed');
        Assert.isTrue(!apiNames.contains('MAS_GIC_RunConfigInvocable'),
            'This package\'s own recursive launcher should be excluded from the target picker');
        Assert.isTrue(!apiNames.contains('MAS_GIC_ConfigController'),
            'A class that only mentions "@InvocableMethod" in a comment/string (like this very method\'s own '
            + 'doc comment and filter code) must not be mistaken for a class that actually has the annotation');
        Assert.isTrue(!apiNames.contains('MAS_GIC_ConfigControllerTest'),
            'A class that only mentions "@InvocableMethod" in an assertion message must not be mistaken for a real match');
    }

    @IsTest
    static void hasInvocableMethodAnnotationIgnoresCommentsAndStringLiterals() {
        Assert.isTrue(
            MAS_GIC_ConfigController.hasInvocableMethodAnnotation('public class Foo {\n    @InvocableMethod\n    public static void run() {}\n}'),
            'A genuine annotation on its own line should be detected'
        );
        Assert.isTrue(
            MAS_GIC_ConfigController.hasInvocableMethodAnnotation('public class Foo {\n\t@InvocableMethod(label=\'x\')\n    public static void run() {}\n}'),
            'Leading whitespace/tabs before the annotation should still be detected'
        );
        Assert.isTrue(
            !MAS_GIC_ConfigController.hasInvocableMethodAnnotation('/** Mentions @InvocableMethod in a doc comment only. */\npublic class Foo {}'),
            'A mention inside a comment (not starting its own line) should not count'
        );
        Assert.isTrue(
            !MAS_GIC_ConfigController.hasInvocableMethodAnnotation('public class Foo {\n    String s = \'@InvocableMethod\';\n}'),
            'A mention inside a string literal should not count'
        );
        Assert.isTrue(!MAS_GIC_ConfigController.hasInvocableMethodAnnotation(null), 'Null body returns false');
        Assert.isTrue(!MAS_GIC_ConfigController.hasInvocableMethodAnnotation(''), 'Blank body returns false');
    }

    @IsTest
    static void runNowStartsBatch() {
        insert new Account(Name = 'Run Acct');
        MAS_GIC_Configuration__c cfg = makeConfig();
        insert new MAS_GIC_Field_Mapping__c(
            Configuration__c = cfg.Id, Source_Field_Name__c = 'Name',
            Target_Parameter_Name__c = 'recordName', Is_Literal__c = false
        );

        Test.startTest();
        Id jobId = MAS_GIC_ConfigController.runNow(cfg.Id);
        Test.stopTest();

        Assert.areNotEqual(null, jobId, 'Batch job id returned');
        List<MAS_GIC_Log__c> logs = [SELECT Id FROM MAS_GIC_Log__c WHERE Configuration__c = :cfg.Id];
        Assert.isTrue(!logs.isEmpty(), 'A run log was created');
    }

    @IsTest
    static void scheduleAndUnschedule() {
        MAS_GIC_Configuration__c cfg = makeConfig();

        Test.startTest();
        String jobId = MAS_GIC_ConfigController.saveSchedule(cfg.Id, '0 0 6 * * ?');
        Assert.isTrue(String.isNotBlank(jobId), 'Schedule returns a job id');
        MAS_GIC_Configuration__c scheduled = [
            SELECT Scheduled_Job_Id__c, Schedule_Type__c, Schedule_Description__c
            FROM MAS_GIC_Configuration__c WHERE Id = :cfg.Id
        ];
        Assert.areEqual(jobId, scheduled.Scheduled_Job_Id__c, 'Job id stored');
        Assert.areEqual('Scheduled', scheduled.Schedule_Type__c, 'Schedule type set');
        Assert.areEqual('Daily at 6:00 AM', scheduled.Schedule_Description__c, 'Plain-English schedule description stamped');

        MAS_GIC_ConfigController.unschedule(cfg.Id);
        Test.stopTest();

        MAS_GIC_Configuration__c cleared = [SELECT Scheduled_Job_Id__c FROM MAS_GIC_Configuration__c WHERE Id = :cfg.Id];
        Assert.areEqual(null, cleared.Scheduled_Job_Id__c, 'Job id cleared after unschedule');
    }

    @IsTest
    static void scheduleDescriptionOnlyPopulatedWhenScheduledAndActive() {
        MAS_GIC_Configuration__c cfg = makeConfig(); // Active__c = true, Schedule_Type__c defaults to Manual
        MAS_GIC_ConfigController.saveSchedule(cfg.Id, '0 0 6 * * ?');

        MAS_GIC_Configuration__c afterSchedule = [
            SELECT Schedule_Description__c FROM MAS_GIC_Configuration__c WHERE Id = :cfg.Id
        ];
        Assert.areEqual('Daily at 6:00 AM', afterSchedule.Schedule_Description__c,
            'Scheduled + Active populates the description');

        update new MAS_GIC_Configuration__c(Id = cfg.Id, Active__c = false);
        MAS_GIC_Configuration__c afterDeactivate = [
            SELECT Schedule_Description__c FROM MAS_GIC_Configuration__c WHERE Id = :cfg.Id
        ];
        Assert.areEqual(null, afterDeactivate.Schedule_Description__c,
            'Deactivating clears the description even though Schedule_Type__c is still Scheduled');

        update new MAS_GIC_Configuration__c(Id = cfg.Id, Active__c = true, Schedule_Type__c = 'Manual');
        MAS_GIC_Configuration__c afterSwitchToManual = [
            SELECT Schedule_Description__c FROM MAS_GIC_Configuration__c WHERE Id = :cfg.Id
        ];
        Assert.areEqual(null, afterSwitchToManual.Schedule_Description__c,
            'Switching back to Manual clears the description even though Active__c is true');
    }

    @IsTest
    static void crudHelpers() {
        MAS_GIC_Configuration__c cfg = makeConfig();

        MAS_GIC_Configuration__c fetched = MAS_GIC_ConfigController.getConfig(cfg.Id);
        Assert.areEqual(cfg.Id, fetched.Id, 'getConfig');

        fetched.Description__c = 'Updated';
        Id savedId = MAS_GIC_ConfigController.saveConfig(fetched);
        Assert.areEqual(cfg.Id, savedId, 'saveConfig upserts');

        List<MAS_GIC_Field_Mapping__c> mappings = new List<MAS_GIC_Field_Mapping__c>{
            new MAS_GIC_Field_Mapping__c(Source_Field_Name__c = 'Name', Target_Parameter_Name__c = 'recordName', Is_Literal__c = false),
            new MAS_GIC_Field_Mapping__c(Source_Field_Name__c = 'Id', Target_Parameter_Name__c = 'recordId', Is_Literal__c = false)
        };
        MAS_GIC_ConfigController.saveMappings(cfg.Id, mappings);
        Assert.areEqual(2, MAS_GIC_ConfigController.getMappings(cfg.Id).size(), 'Mappings saved');

        // Replace with a single mapping
        MAS_GIC_ConfigController.saveMappings(cfg.Id, new List<MAS_GIC_Field_Mapping__c>{
            new MAS_GIC_Field_Mapping__c(Source_Field_Name__c = 'Name', Target_Parameter_Name__c = 'recordName', Is_Literal__c = false)
        });
        Assert.areEqual(1, MAS_GIC_ConfigController.getMappings(cfg.Id).size(), 'Mappings replaced');

        Assert.areNotEqual(null, MAS_GIC_ConfigController.getLogs(cfg.Id), 'getLogs returns a list');
    }

    @IsTest
    static void getLogsExcludesChunkChildLogs() {
        MAS_GIC_Configuration__c cfg = makeConfig();
        MAS_GIC_Log__c summary = new MAS_GIC_Log__c(
            Configuration__c = cfg.Id,
            Message_Type__c = 'Success',
            Message__c = 'Run complete: 1 processed, 0 failed',
            Timestamp__c = System.now()
        );
        insert summary;
        insert new MAS_GIC_Log__c(
            Configuration__c = cfg.Id,
            Parent_Log__c = summary.Id,
            Message_Type__c = 'Success',
            Message__c = '1 of 1 record(s) processed in this batch',
            Long_Message__c = '001000000000001: OK',
            Timestamp__c = System.now()
        );

        Test.startTest();
        List<MAS_GIC_Log__c> logs = MAS_GIC_ConfigController.getLogs(cfg.Id);
        Test.stopTest();

        Assert.areEqual(1, logs.size(), 'Only the top-level summary log should be returned');
        Assert.areEqual(summary.Id, logs[0].Id, 'The returned log should be the summary, not its chunk child');
    }

    @IsTest
    static void unscheduleOnNeverScheduledConfigIsANoOp() {
        MAS_GIC_Configuration__c cfg = makeConfig();

        Test.startTest();
        MAS_GIC_ConfigController.unschedule(cfg.Id);
        Test.stopTest();

        MAS_GIC_Configuration__c after = [SELECT Scheduled_Job_Id__c FROM MAS_GIC_Configuration__c WHERE Id = :cfg.Id];
        Assert.areEqual(null, after.Scheduled_Job_Id__c, 'Job id stays null when nothing was scheduled');
    }

    @IsTest
    static void unscheduleToleratesAJobThatWasAlreadyAborted() {
        MAS_GIC_Configuration__c cfg = makeConfig();
        String jobId = MAS_GIC_ConfigController.saveSchedule(cfg.Id, '0 0 6 * * ?');
        System.abortJob(jobId); // pre-abort it, so the controller's own abortJob call fails

        Test.startTest();
        MAS_GIC_ConfigController.unschedule(cfg.Id);
        Test.stopTest();

        MAS_GIC_Configuration__c after = [SELECT Scheduled_Job_Id__c FROM MAS_GIC_Configuration__c WHERE Id = :cfg.Id];
        Assert.areEqual(null, after.Scheduled_Job_Id__c, 'Job id is still cleared even though the abortJob call itself failed');
    }

    @IsTest
    static void saveScheduleWithInvalidCronThrowsAuraHandledException() {
        MAS_GIC_Configuration__c cfg = makeConfig();

        Test.startTest();
        try {
            MAS_GIC_ConfigController.saveSchedule(cfg.Id, 'not a valid cron expression');
            Assert.fail('Expected an AuraHandledException for an invalid cron expression');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'Invalid cron expression should surface as an AuraHandledException');
        }
        Test.stopTest();
    }

    @IsTest
    static void getActionInputsSupportsFlowTargets() {
        Test.startTest();
        List<MAS_GIC_ConfigController.InputParam> inputs = MAS_GIC_ConfigController.getActionInputs('Flow', 'MAS_GIC_SampleFlow');
        Test.stopTest();

        Assert.areNotEqual(null, inputs, 'Flow inputs returned');
        Assert.isTrue(inputs.size() >= 1, 'Sample flow exposes input parameters');
    }

    @IsTest
    static void parseSelectColumnsSkipsNestedSubqueries() {
        List<String> columns = MAS_GIC_ConfigController.parseSelectColumns(
            'SELECT Id, Name, (SELECT Id, LastName FROM Contacts) FROM Account'
        );

        Assert.areEqual(2, columns.size(), 'Only the top-level columns should be returned');
        Assert.isTrue(columns.contains('Id'), 'Id should be included');
        Assert.isTrue(columns.contains('Name'), 'Name should be included');
        for (String col : columns) {
            Assert.isTrue(!col.startsWith('('), 'No subquery expression should be included in the column list');
        }
    }

    @IsTest
    static void parseSelectColumnsReturnsEmptyWithoutATopLevelFrom() {
        List<String> columns = MAS_GIC_ConfigController.parseSelectColumns('SELECT Id, Name');
        Assert.isTrue(columns.isEmpty(), 'A SOQL string with no top-level FROM clause yields no columns');
    }

    @IsTest
    static void getActionInputsReturnsEmptyForBlankActionName() {
        List<MAS_GIC_ConfigController.InputParam> inputs = MAS_GIC_ConfigController.getActionInputs('Apex', '');
        Assert.isTrue(inputs.isEmpty(), 'A blank action name returns an empty list rather than describing anything');
    }

    @IsTest
    static void getActionInputsReturnsEmptyForUnknownAction() {
        // Invocable.Action.getDescribe() doesn't throw for an unknown custom
        // action (only invoking it does - see MAS_GIC_BatchRunnerTest.invalidTargetIsLoggedAsError),
        // so this describes as "no inputs" rather than raising an error.
        List<MAS_GIC_ConfigController.InputParam> inputs = MAS_GIC_ConfigController.getActionInputs('Apex', 'MAS_GIC_NoSuchAction_ZZZ');
        Assert.isTrue(inputs.isEmpty(), 'An unknown target action describes as having no input parameters');
    }

    @IsTest
    static void previewSourceReturnsEmptyResultForBlankSoql() {
        MAS_GIC_ConfigController.PreviewResult result = MAS_GIC_ConfigController.previewSource('');
        Assert.areEqual(0, result.totalPreviewed, 'A blank SOQL string previews nothing');
        Assert.isTrue(result.columns.isEmpty(), 'No columns for a blank query');
        Assert.isTrue(result.rows.isEmpty(), 'No rows for a blank query');
    }

    @IsTest
    static void previewSourceThrowsForMalformedSoql() {
        try {
            MAS_GIC_ConfigController.previewSource('SELECT Id FROM Not_A_Real_Object__x');
            Assert.fail('Expected an AuraHandledException for an invalid SOQL query');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'An invalid preview query should surface as an AuraHandledException');
        }
    }

    @IsTest
    static void runNowThrowsForUnknownConfig() {
        MAS_GIC_Configuration__c cfg = makeConfig();
        Id deletedId = cfg.Id;
        delete cfg;

        try {
            MAS_GIC_ConfigController.runNow(deletedId);
            Assert.fail('Expected an AuraHandledException when the configuration no longer exists');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'A missing configuration should surface as an AuraHandledException');
        }
    }

    @IsTest
    static void unscheduleThrowsForUnknownConfig() {
        MAS_GIC_Configuration__c cfg = makeConfig();
        Id deletedId = cfg.Id;
        delete cfg;

        try {
            MAS_GIC_ConfigController.unschedule(deletedId);
            Assert.fail('Expected an AuraHandledException when the configuration no longer exists');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'A missing configuration should surface as an AuraHandledException');
        }
    }

    @IsTest
    static void saveConfigThrowsOnDuplicateDeveloperName() {
        makeConfig(); // takes Developer_Name__c = 'ctrl_config'

        MAS_GIC_Configuration__c duplicate = new MAS_GIC_Configuration__c(
            Name = 'Duplicate Config',
            Developer_Name__c = 'ctrl_config', // unique field - collides with makeConfig()
            Active__c = true,
            Batch_Size__c = 50,
            Source_SOQL_Query__c = 'SELECT Id FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = 'MAS_GIC_SampleAction'
        );

        try {
            MAS_GIC_ConfigController.saveConfig(duplicate);
            Assert.fail('Expected an AuraHandledException for a duplicate Developer Name');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'A unique-field violation should surface as an AuraHandledException');
        }
    }

    @IsTest
    static void getScheduledJobsListsOnlyActivelyScheduledConfigs() {
        MAS_GIC_Configuration__c scheduled = makeConfig();
        MAS_GIC_ConfigController.saveSchedule(scheduled.Id, '0 0 6 * * ?');

        MAS_GIC_Configuration__c unscheduledCfg = new MAS_GIC_Configuration__c(
            Name = 'Manual Config',
            Developer_Name__c = 'manual_config',
            Active__c = true,
            Batch_Size__c = 50,
            Source_SOQL_Query__c = 'SELECT Id FROM Account',
            Target_Type__c = 'Apex',
            Target_Action_Name__c = 'MAS_GIC_SampleAction'
        );
        insert unscheduledCfg;

        Test.startTest();
        List<MAS_GIC_ConfigController.ScheduledJobInfo> jobs = MAS_GIC_ConfigController.getScheduledJobs();
        Test.stopTest();

        Assert.areEqual(1, jobs.size(), 'Only the scheduled configuration should be listed');
        MAS_GIC_ConfigController.ScheduledJobInfo info = jobs[0];
        Assert.areEqual(scheduled.Id, info.configId, 'Config id matches the scheduled configuration');
        Assert.areEqual('Ctrl Config', info.configName, 'Config name is included');
        Assert.areNotEqual(null, info.jobId, 'CronTrigger id is included');
        Assert.areNotEqual(null, info.jobName, 'CronTrigger job name is included');
        Assert.areEqual('0 0 6 * * ?', info.cronExpression, 'Cron expression comes from the live CronTrigger');
        Assert.areEqual('Daily at 6:00 AM', info.scheduleDescription, 'Plain-English description is derived from the cron');
    }

    @IsTest
    static void getScheduledJobsExcludesAnOrphanedJobReference() {
        MAS_GIC_Configuration__c cfg = makeConfig();
        String jobId = MAS_GIC_ConfigController.saveSchedule(cfg.Id, '0 0 6 * * ?');
        System.abortJob(jobId); // CronTrigger is gone, but Scheduled_Job_Id__c/Schedule_Type__c still point at it

        Test.startTest();
        List<MAS_GIC_ConfigController.ScheduledJobInfo> jobs = MAS_GIC_ConfigController.getScheduledJobs();
        Test.stopTest();

        Assert.isTrue(jobs.isEmpty(), 'A config whose stored job id no longer resolves to a CronTrigger is skipped');
    }

    @IsTest
    static void getScheduledJobsReturnsEmptyWhenNothingIsScheduled() {
        makeConfig(); // Schedule_Type__c defaults to null/Manual

        Test.startTest();
        List<MAS_GIC_ConfigController.ScheduledJobInfo> jobs = MAS_GIC_ConfigController.getScheduledJobs();
        Test.stopTest();

        Assert.isTrue(jobs.isEmpty(), 'No configurations are scheduled, so the list is empty');
    }

    @IsTest
    static void saveMappingsThrowsForUnknownConfig() {
        MAS_GIC_Configuration__c cfg = makeConfig();
        Id deletedId = cfg.Id;
        delete cfg;

        try {
            MAS_GIC_ConfigController.saveMappings(deletedId, new List<MAS_GIC_Field_Mapping__c>{
                new MAS_GIC_Field_Mapping__c(Source_Field_Name__c = 'Name', Target_Parameter_Name__c = 'recordName', Is_Literal__c = false)
            });
            Assert.fail('Expected an AuraHandledException when the parent configuration no longer exists');
        } catch (AuraHandledException e) {
            Assert.isTrue(true, 'An invalid Configuration__c reference should surface as an AuraHandledException');
        }
    }
}
