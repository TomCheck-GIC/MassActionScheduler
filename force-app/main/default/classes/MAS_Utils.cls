/**
 * Shared helpers for Mass Action Scheduler.
 */
public with sharing class MAS_Utils {
    public static final Integer DEFAULT_BATCH_SIZE = 50;
    public static final Integer MAX_BATCH_SIZE = 200;

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
}
