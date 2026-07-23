/**
 * Batch engine for Mass Action Scheduler.
 *
 * Iterates the records returned by a configuration's SOQL query and invokes the
 * configured target (autolaunched Flow or invocable Apex) for each record using
 * the native Apex Invocable.Action framework — no HTTP callout, so no Named
 * Credential / Connected App is required.
 *
 * Per-record input parameters are built from MAS_GIC_Field_Mapping__c rows. Results
 * are captured per record (Invocable.Action.Result) and summarized into MAS_GIC_Log__c.
 *
 * Runs `without sharing` by design: a mass action configured by an admin must
 * process every record its source query returns, regardless of the record-level
 * sharing visibility of whichever user's automation happened to launch the run
 * (scheduled job, on-demand click, or an invocable action called from a Flow).
 */
public without sharing class MAS_GIC_BatchRunner implements Database.Batchable<SObject>, Database.Stateful {
    private final Id configId;
    private MAS_GIC_Configuration__c config;
    private List<MAS_GIC_Field_Mapping__c> mappings;

    private Integer processedRecords = 0;
    private Integer failedRecords = 0;
    private Integer totalBatches = 0;
    private Integer failedBatches = 0;
    private Map<String, String> paramTypesByName;

    // The "Batch job started" log's id, captured so every per-batch chunk log
    // in execute() can be parented to it immediately (see execute() below).
    private Id startLogId;

    public MAS_GIC_BatchRunner(Id configId) {
        this.configId = configId;
    }

    /**
     * A "Batch job started" log is written here (once the query locator is
     * known to be valid) rather than in execute(), so it lands before any
     * per-batch work and is visible immediately - the same "started"/"finished"
     * bookend logging the original dca_mass_action package produced. It's
     * created with no Parent_Log__c yet (nothing to nest it under until the
     * run finishes), so it's the one top-level entry getLogs() surfaces for
     * the duration of the run; finish() folds it under the final summary once
     * the run completes.
     *
     * Any failure here (bad SOQL, missing configuration, etc.) happens before
     * any record work begins, so it's caught and logged as an Error rather
     * than left as a silent AsyncApexJob failure with no MAS_GIC_Log__c trail -
     * then rethrown so the job's own status still reflects the failure.
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        try {
            this.config = [
                SELECT Id, Name, Source_SOQL_Query__c, Target_Type__c, Target_Action_Name__c
                FROM MAS_GIC_Configuration__c
                WHERE Id = :configId
                LIMIT 1
            ];
            this.mappings = [
                SELECT Source_Field_Name__c, Target_Parameter_Name__c, Is_Literal__c
                FROM MAS_GIC_Field_Mapping__c
                WHERE Configuration__c = :configId
            ];
            update new MAS_GIC_Configuration__c(Id = configId, Last_Run_Status__c = MAS_GIC_Utils.STATUS_RUNNING);
            Database.QueryLocator locator = Database.getQueryLocator(config.Source_SOQL_Query__c);
            MAS_GIC_Log__c startLog = new MAS_GIC_Log__c(
                Configuration__c = configId,
                Message_Type__c = MAS_GIC_Utils.LOG_TYPE_INFO,
                Message__c = 'Batch job started.',
                Job_Id__c = bc.getJobId(),
                Timestamp__c = System.now()
            );
            insert startLog;
            this.startLogId = startLog.Id;
            return locator;
        } catch (Exception e) {
            logStartFailure(bc, e);
            throw e;
        }
    }

    private void logStartFailure(Database.BatchableContext bc, Exception e) {
        insert new MAS_GIC_Log__c(
            Configuration__c = configId,
            Message_Type__c = MAS_GIC_Utils.LOG_TYPE_ERROR,
            Message__c = 'Batch job failed to start: ' + e.getMessage(),
            Job_Id__c = bc.getJobId(),
            Timestamp__c = System.now()
        );
        try {
            update new MAS_GIC_Configuration__c(Id = configId, Last_Run_Status__c = MAS_GIC_Utils.STATUS_FAILED);
        } catch (Exception ignored) {
            // Configuration may itself be missing/deleted; the error log above is the source of truth.
            System.debug(LoggingLevel.WARN, 'MAS_GIC_BatchRunner.logStartFailure: could not mark configuration Failed: '
                + ignored.getMessage());
        }
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        totalBatches++;
        Integer batchFailed = 0;
        List<String> recordLines = new List<String>();

        try {
            String actionType = MAS_GIC_Utils.toActionType(config.Target_Type__c);
            Invocable.Action action = Invocable.Action.createCustomAction(actionType, config.Target_Action_Name__c);
            if (paramTypesByName == null) {
                paramTypesByName = describeParamTypes(action);
            }

            // Build one invocation per record, then invoke the action once.
            List<Map<String, Object>> invocations = new List<Map<String, Object>>();
            for (SObject record : scope) {
                Map<String, Object> params = new Map<String, Object>();
                for (MAS_GIC_Field_Mapping__c m : mappings) {
                    Object value = (m.Is_Literal__c == true)
                        ? (Object) m.Source_Field_Name__c
                        : MAS_GIC_Utils.getFieldValue(record, m.Source_Field_Name__c);
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
        insert new MAS_GIC_Log__c(
            Configuration__c = configId,
            // Parented to the start log immediately, not left dangling at the
            // top level until finish() runs - otherwise every chunk log would
            // flood getLogs()'s top-level view for the entire duration of a
            // long-running batch job, only collapsing down once it finishes.
            Parent_Log__c = startLogId,
            Message_Type__c = (batchFailed > 0) ? MAS_GIC_Utils.LOG_TYPE_ERROR : MAS_GIC_Utils.LOG_TYPE_SUCCESS,
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
            ? MAS_GIC_Utils.STATUS_SUCCESS
            : (processedRecords > 0 ? MAS_GIC_Utils.STATUS_COMPLETED_WITH_ERRORS : MAS_GIC_Utils.STATUS_FAILED);

        MAS_GIC_Log__c summary = new MAS_GIC_Log__c(
            Configuration__c = configId,
            Message_Type__c = (failedRecords == 0) ? MAS_GIC_Utils.LOG_TYPE_SUCCESS : MAS_GIC_Utils.LOG_TYPE_ERROR,
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

        // Flatten every log tied to this run - the start log, and every chunk
        // log already parented beneath it from execute() - to be a *direct*
        // child of the final summary, not left nested two levels deep under
        // the start log. Chunk logs were parented to the start log the moment
        // each was written (so they never sit unparented at the top level
        // while the run is still in progress), but once the run is done the
        // summary's own Child Logs related list should show the start marker
        // and every batch chunk as direct siblings, matching what an admin
        // browsing from the summary record actually expects to see.
        List<MAS_GIC_Log__c> children = [
            SELECT Id FROM MAS_GIC_Log__c WHERE Job_Id__c = :jobId AND Id != :summary.Id
        ];
        if (!children.isEmpty()) {
            for (MAS_GIC_Log__c child : children) {
                child.Parent_Log__c = summary.Id;
            }
            update children;
        }

        // Symmetric "finished" bookend to the "Batch job started." log written
        // in start() - the same started/finished pair the original
        // dca_mass_action package produced - as a direct child of the summary,
        // alongside the start log and every chunk log.
        insert new MAS_GIC_Log__c(
            Configuration__c = configId,
            Parent_Log__c = summary.Id,
            Message_Type__c = MAS_GIC_Utils.LOG_TYPE_INFO,
            Message__c = 'Batch job completed.',
            Job_Id__c = jobId,
            Timestamp__c = System.now()
        );

        update new MAS_GIC_Configuration__c(
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
