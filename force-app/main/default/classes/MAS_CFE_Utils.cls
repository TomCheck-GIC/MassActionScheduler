/**
 * Shared helpers for Mass Action Scheduler.
 */
public with sharing class MAS_CFE_Utils {
    public static final Integer DEFAULT_BATCH_SIZE = 50;
    public static final Integer MAX_BATCH_SIZE = 200;

    public static final String TARGET_TYPE_APEX = 'Apex';
    public static final String STATUS_RUNNING = 'Running';
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_FAILED = 'Failed';
    public static final String STATUS_COMPLETED_WITH_ERRORS = 'Completed with Errors';
    public static final String LOG_TYPE_ERROR = 'Error';
    public static final String LOG_TYPE_SUCCESS = 'Success';
    public static final String LOG_TYPE_INFO = 'Informational';

    /**
     * Normalizes a configured batch size to a valid Database.executeBatch scope
     * (1-200), falling back to the default when unset or out of range.
     */
    public static Integer resolveBatchSize(Decimal configured) {
        if (configured == null || configured <= 0) {
            return DEFAULT_BATCH_SIZE;
        }
        Integer value = (Integer) configured;
        return (value > MAX_BATCH_SIZE) ? MAX_BATCH_SIZE : value;
    }

    /**
     * Maps a configuration's Target_Type__c picklist value to the
     * Invocable.Action.createCustomAction action-type token.
     */
    public static String toActionType(String targetType) {
        return (targetType == TARGET_TYPE_APEX) ? 'apex' : 'flow';
    }

    /**
     * Resolves a (possibly dotted) field path against a source record.
     * Supports parent traversal such as Owner.Email or Account.Name.
     * Throws if a traversal step is invalid; callers that need a best-effort
     * (e.g. preview UI) result should catch at their own call site.
     */
    public static Object getFieldValue(SObject record, String fieldPath) {
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

    /**
     * Produces a short, human-readable description of a Quartz cron expression,
     * mirroring the frequency shapes the masCfeConfigWizard schedule builder
     * generates (hourly/daily/weekly/monthly). Anything that doesn't match one
     * of those shapes (or a hand-typed custom cron) falls back to the raw
     * expression rather than guessing.
     */
    public static String describeCron(String cron) {
        if (String.isBlank(cron)) {
            return '';
        }
        List<String> parts = cron.trim().split('\\s+');
        if (parts.size() != 6) {
            return cron;
        }
        String sec = parts[0];
        String min = parts[1];
        String hr = parts[2];
        String dom = parts[3];
        String mon = parts[4];
        String dow = parts[5];

        if (sec == '0' && min == '0' && hr == '*' && dom == '*' && mon == '*' && dow == '?') {
            return 'Every hour';
        }
        if (sec == '0' && isNumericCronToken(min) && isNumericCronToken(hr) && dom == '*' && mon == '*' && dow == '?') {
            return 'Daily at ' + formatCronTime(hr, min);
        }
        if (sec == '0' && isNumericCronToken(min) && isNumericCronToken(hr) && dom == '?' && mon == '*' && isSimpleDayOfWeekList(dow)) {
            return 'Weekly on ' + dow + ' at ' + formatCronTime(hr, min);
        }
        if (sec == '0' && isNumericCronToken(min) && isNumericCronToken(hr)
            && (dom == 'L' || isNumericCronToken(dom)) && mon == '*' && dow == '?') {
            String dayLabel = (dom == 'L') ? 'the last day' : 'day ' + dom;
            return 'Monthly on ' + dayLabel + ' at ' + formatCronTime(hr, min);
        }
        return cron;
    }

    /**
     * Keeps Schedule_Description__c consistent with Schedule_Type__c/Active__c/
     * Schedule_Cron__c on every insert/update, regardless of which code path
     * (wizard save, saveSchedule, unschedule, data load) touched the record.
     * Populated only while the config is both Scheduled and Active; cleared
     * otherwise so a stale description can't outlive the state it described.
     */
    public static void syncScheduleDescription(List<MAS_CFE_Configuration__c> records) {
        for (MAS_CFE_Configuration__c c : records) {
            c.Schedule_Description__c = (c.Active__c == true && c.Schedule_Type__c == 'Scheduled')
                ? describeCron(c.Schedule_Cron__c)
                : null;
        }
    }

    private static Boolean isNumericCronToken(String token) {
        return Pattern.matches('^\\d+$', token);
    }

    private static final Set<String> VALID_DAY_OF_WEEK_TOKENS = new Set<String>{
        'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'
    };

    /**
     * True only for a plain comma-separated list of day-of-week abbreviations
     * (e.g. "MON" or "MON,WED,FRI"). Excludes Quartz's "day#occurrence" syntax
     * (e.g. "6#3" = every 3rd Friday) and other non-weekly day-of-week shapes,
     * which fall back to the raw cron expression instead of being mislabeled
     * as a simple weekly schedule.
     */
    private static Boolean isSimpleDayOfWeekList(String dow) {
        if (String.isBlank(dow) || dow == '?') {
            return false;
        }
        for (String token : dow.split(',')) {
            if (!VALID_DAY_OF_WEEK_TOKENS.contains(token.trim().toUpperCase())) {
                return false;
            }
        }
        return true;
    }

    private static String formatCronTime(String hr, String min) {
        Integer h = Integer.valueOf(hr);
        Integer m = Integer.valueOf(min);
        String ampm = (h < 12) ? 'AM' : 'PM';
        Integer h12 = Math.mod(h, 12);
        if (h12 == 0) {
            h12 = 12;
        }
        return h12 + ':' + String.valueOf(m).leftPad(2, '0') + ' ' + ampm;
    }
}
