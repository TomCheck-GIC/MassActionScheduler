/**
 * Batch engine for Mass Action Scheduler.
 *
 * Iterates the records returned by a configuration's SOQL query and invokes the
 * configured target (autolaunched Flow or invocable Apex) for each record using
 * the native Apex Invocable.Action framework — no HTTP callout, so no Named
 * Credential / Connected App is required.
 *
 * Per-record input parameters are built from MAS_Field_Mapping__c rows. Results
 * are captured per record (Invocable.Action.Result) and summarized into MAS_Log__c.
 */
public with sharing class MAS_BatchRunner implements Database.Batchable<SObject>, Database.Stateful {
    private final Id configId;
    private MAS_Configuration__c config;
    private List<MAS_Field_Mapping__c> mappings;

    private Integer processedRecords = 0;
    private Integer failedRecords = 0;
    private Integer totalBatches = 0;
    private Integer failedBatches = 0;

    public MAS_BatchRunner(Id configId) {
        this.configId = configId;
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        this.config = [
            SELECT Id, Name, Source_SOQL_Query__c, Target_Type__c, Target_Action_Name__c
            FROM MAS_Configuration__c
            WHERE Id = :configId
            LIMIT 1
        ];
        this.mappings = [
            SELECT Source_Field_Name__c, Target_Parameter_Name__c, Is_Literal__c
            FROM MAS_Field_Mapping__c
            WHERE Configuration__c = :configId
        ];
        update new MAS_Configuration__c(Id = configId, Last_Run_Status__c = 'Running');
        return Database.getQueryLocator(config.Source_SOQL_Query__c);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        totalBatches++;
        Integer batchFailed = 0;
        List<String> errorLines = new List<String>();

        try {
            // Build one invocation per record, then invoke the action once.
            List<Map<String, Object>> invocations = new List<Map<String, Object>>();
            for (SObject record : scope) {
                Map<String, Object> params = new Map<String, Object>();
                for (MAS_Field_Mapping__c m : mappings) {
                    Object value = (m.Is_Literal__c == true)
                        ? (Object) m.Source_Field_Name__c
                        : getFieldValue(record, m.Source_Field_Name__c);
                    params.put(m.Target_Parameter_Name__c, value);
                }
                invocations.add(params);
            }

            String actionType = (config.Target_Type__c == 'Apex') ? 'apex' : 'flow';
            Invocable.Action action = Invocable.Action.createCustomAction(actionType, config.Target_Action_Name__c);
            action.setInvocations(invocations);

            // invoke() after building params (and before any DML below) so a target
            // that performs a callout does not hit "uncommitted work pending".
            List<Invocable.Action.Result> results = action.invoke();

            for (Integer i = 0; i < results.size(); i++) {
                Invocable.Action.Result r = results[i];
                if (r.isSuccess()) {
                    processedRecords++;
                } else {
                    failedRecords++;
                    batchFailed++;
                    errorLines.add(describeFailure(scope, i, r));
                }
            }
        } catch (Exception e) {
            // Whole-chunk failure (e.g. invalid action name, malformed params).
            failedRecords += scope.size();
            batchFailed = scope.size();
            errorLines.add('Batch failed: ' + e.getMessage());
        }

        if (batchFailed > 0) {
            failedBatches++;
            insert new MAS_Log__c(
                Configuration__c = configId,
                Message_Type__c = 'Error',
                Message__c = batchFailed + ' of ' + scope.size() + ' record(s) failed in this batch',
                Long_Message__c = String.join(errorLines, '\n').abbreviate(32768),
                Job_Id__c = bc.getJobId(),
                Timestamp__c = System.now()
            );
        }
    }

    public void finish(Database.BatchableContext bc) {
        Id jobId = bc.getJobId();
        Integer totalRecords = processedRecords + failedRecords;
        Decimal successPct = (totalRecords > 0)
            ? (((Decimal) processedRecords / totalRecords) * 100).setScale(2)
            : 100;
        String status = (failedRecords == 0)
            ? 'Success'
            : (processedRecords > 0 ? 'Completed with Errors' : 'Failed');

        MAS_Log__c summary = new MAS_Log__c(
            Configuration__c = configId,
            Message_Type__c = (failedRecords == 0) ? 'Success' : 'Error',
            Message__c = 'Run complete: ' + processedRecords + ' processed, ' + failedRecords + ' failed',
            Job_Id__c = jobId,
            Total_Records__c = totalRecords,
            Processed_Records__c = processedRecords,
            Failed_Records__c = failedRecords,
            Total_Batches__c = totalBatches,
            Processed_Batches__c = totalBatches - failedBatches,
            Failed_Batches__c = failedBatches,
            Batch_Success_Percentage__c = successPct,
            Timestamp__c = System.now()
        );
        insert summary;

        // Link any per-batch error logs to the summary log.
        List<MAS_Log__c> children = [
            SELECT Id FROM MAS_Log__c WHERE Job_Id__c = :jobId AND Id != :summary.Id
        ];
        if (!children.isEmpty()) {
            for (MAS_Log__c child : children) {
                child.Parent_Log__c = summary.Id;
            }
            update children;
        }

        update new MAS_Configuration__c(
            Id = configId,
            Last_Run_Status__c = status,
            Last_Run_Completed_Date__c = System.now()
        );
    }

    /**
     * Resolves a (possibly dotted) field path against a source record.
     * Supports parent traversal such as Owner.Email or Account.Name.
     */
    @TestVisible
    private Object getFieldValue(SObject record, String fieldPath) {
        if (String.isBlank(fieldPath) || record == null) {
            return null;
        }
        if (!fieldPath.contains('.')) {
            return record.get(fieldPath);
        }
        List<String> parts = fieldPath.split('\\.');
        SObject current = record;
        for (Integer i = 0; i < parts.size() - 1; i++) {
            current = current.getSObject(parts[i]);
            if (current == null) {
                return null;
            }
        }
        return current.get(parts[parts.size() - 1]);
    }

    private String describeFailure(List<SObject> scope, Integer index, Invocable.Action.Result r) {
        String recordId = (index < scope.size() && scope[index].get('Id') != null)
            ? String.valueOf(scope[index].get('Id'))
            : '(row ' + index + ')';
        List<String> msgs = new List<String>();
        if (r.getErrors() != null) {
            for (Invocable.Action.Error err : r.getErrors()) {
                msgs.add(err.getMessage());
            }
        }
        return recordId + ': ' + (msgs.isEmpty() ? 'Unknown error' : String.join(msgs, '; '));
    }
}
