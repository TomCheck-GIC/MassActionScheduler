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
 *
 * Runs `without sharing` by design: a mass action configured by an admin must
 * process every record its source query returns, regardless of the record-level
 * sharing visibility of whichever user's automation happened to launch the run
 * (scheduled job, on-demand click, or an invocable action called from a Flow).
 */
public without sharing class MAS_BatchRunner implements Database.Batchable<SObject>, Database.Stateful {
    private final Id configId;
    private MAS_Configuration__c config;
    private List<MAS_Field_Mapping__c> mappings;

    private Integer processedRecords = 0;
    private Integer failedRecords = 0;
    private Integer totalBatches = 0;
    private Integer failedBatches = 0;
    private Map<String, String> paramTypesByName;

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
        update new MAS_Configuration__c(Id = configId, Last_Run_Status__c = MAS_Utils.STATUS_RUNNING);
        return Database.getQueryLocator(config.Source_SOQL_Query__c);
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        totalBatches++;
        Integer batchFailed = 0;
        List<String> recordLines = new List<String>();

        try {
            String actionType = MAS_Utils.toActionType(config.Target_Type__c);
            Invocable.Action action = Invocable.Action.createCustomAction(actionType, config.Target_Action_Name__c);
            if (paramTypesByName == null) {
                paramTypesByName = describeParamTypes(action);
            }

            // Build one invocation per record, then invoke the action once.
            List<Map<String, Object>> invocations = new List<Map<String, Object>>();
            for (SObject record : scope) {
                Map<String, Object> params = new Map<String, Object>();
                for (MAS_Field_Mapping__c m : mappings) {
                    Object value = (m.Is_Literal__c == true)
                        ? (Object) m.Source_Field_Name__c
                        : MAS_Utils.getFieldValue(record, m.Source_Field_Name__c);
                    params.put(m.Target_Parameter_Name__c, coerceForTarget(value, paramTypesByName.get(m.Target_Parameter_Name__c)));
                }
                invocations.add(params);
            }

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
                }
                recordLines.add(describeRecord(scope, i, r));
            }
        } catch (Exception e) {
            // Whole-chunk failure (e.g. invalid action name, malformed params).
            failedRecords += scope.size();
            batchFailed = scope.size();
            for (SObject record : scope) {
                recordLines.add(record.Id + ': FAILED - Batch failed: ' + e.getMessage());
            }
        }

        failedBatches += (batchFailed > 0) ? 1 : 0;
        Integer batchProcessed = scope.size() - batchFailed;
        insert new MAS_Log__c(
            Configuration__c = configId,
            Message_Type__c = (batchFailed > 0) ? MAS_Utils.LOG_TYPE_ERROR : MAS_Utils.LOG_TYPE_SUCCESS,
            Message__c = batchProcessed + ' of ' + scope.size() + ' record(s) processed in this batch',
            Long_Message__c = String.join(recordLines, '\n').abbreviate(32768),
            Job_Id__c = bc.getJobId(),
            Total_Records__c = scope.size(),
            Processed_Records__c = batchProcessed,
            Failed_Records__c = batchFailed,
            Batch_Success_Percentage__c = (scope.size() > 0)
                ? (((Decimal) batchProcessed / scope.size()) * 100).setScale(2)
                : 100,
            Timestamp__c = System.now()
        );
    }

    public void finish(Database.BatchableContext bc) {
        Id jobId = bc.getJobId();
        Integer totalRecords = processedRecords + failedRecords;
        Decimal successPct = (totalRecords > 0)
            ? (((Decimal) processedRecords / totalRecords) * 100).setScale(2)
            : 100;
        String status = (failedRecords == 0)
            ? MAS_Utils.STATUS_SUCCESS
            : (processedRecords > 0 ? MAS_Utils.STATUS_COMPLETED_WITH_ERRORS : MAS_Utils.STATUS_FAILED);

        MAS_Log__c summary = new MAS_Log__c(
            Configuration__c = configId,
            Message_Type__c = (failedRecords == 0) ? MAS_Utils.LOG_TYPE_SUCCESS : MAS_Utils.LOG_TYPE_ERROR,
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
     * Maps target input parameter name -> declared data type, so record values
     * pulled from SObject.get() (which returns real Id/Date/etc. Apex types) can
     * be coerced to what Invocable.Action actually expects. This matters most for
     * Flow targets: Flow has no "Id" variable type, so an Id value must become a
     * String before it can be bound to a Flow's Text input.
     */
    @TestVisible
    private Map<String, String> describeParamTypes(Invocable.Action action) {
        Map<String, String> types = new Map<String, String>();
        List<Invocable.Action.DescribeResult> describes = action.getDescribe();
        if (describes != null && !describes.isEmpty()) {
            for (Invocable.Action.InputParameter ip : describes[0].getInputs()) {
                types.put(ip.getName(), ip.getType());
            }
        }
        return types;
    }

    @TestVisible
    private Object coerceForTarget(Object value, String declaredType) {
        if (value instanceof Id && String.isNotBlank(declaredType)) {
            String upperType = declaredType.toUpperCase();
            if (upperType != 'ID' && upperType != 'REFERENCE') {
                return String.valueOf(value);
            }
        }
        return value;
    }

    /**
     * Builds a single "id: OK" or "id: FAILED - <errors>" line for one record
     * in a batch chunk, so every run (success or failure) leaves a browsable
     * per-record list in Long_Message__c.
     */
    private String describeRecord(List<SObject> scope, Integer index, Invocable.Action.Result r) {
        String recordId = (index < scope.size() && scope[index].get('Id') != null)
            ? String.valueOf(scope[index].get('Id'))
            : '(row ' + index + ')';
        if (r.isSuccess()) {
            return recordId + ': OK';
        }
        List<String> msgs = new List<String>();
        if (r.getErrors() != null) {
            for (Invocable.Action.Error err : r.getErrors()) {
                msgs.add(err.getMessage());
            }
        }
        return recordId + ': FAILED - ' + (msgs.isEmpty() ? 'Unknown error' : String.join(msgs, '; '));
    }
}
