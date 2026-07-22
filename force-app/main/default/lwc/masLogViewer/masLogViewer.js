import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getLogs from '@salesforce/apex/MAS_ConfigController.getLogs';

// Datatable columns for the log grid.
const COLUMNS = [
    {
        label: 'Timestamp',
        fieldName: 'Timestamp__c',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    },
    { label: 'Message Type', fieldName: 'Message_Type__c', type: 'text', fixedWidth: 130 },
    { label: 'Message', fieldName: 'Message__c', type: 'text', wrapText: true },
    { label: 'Processed', fieldName: 'Processed_Records__c', type: 'number', fixedWidth: 110 },
    { label: 'Failed', fieldName: 'Failed_Records__c', type: 'number', fixedWidth: 90 },
    {
        label: 'Success %',
        fieldName: 'Batch_Success_Percentage__c',
        type: 'percent',
        fixedWidth: 110,
        typeAttributes: { maximumFractionDigits: 1 }
    },
    {
        type: 'button-icon',
        typeAttributes: {
            iconName: 'utility:preview',
            name: 'view_details',
            title: 'View Details',
            alternativeText: 'View Details',
            variant: 'border-filled'
        },
        fixedWidth: 56
    }
];

export default class MasLogViewer extends NavigationMixin(LightningElement) {
    /** MAS_Configuration__c record Id. */
    @api recordId;

    columns = COLUMNS;
    logs = [];
    error;

    @wire(getLogs, { configId: '$recordId' })
    wiredLogs({ data, error }) {
        if (data) {
            // percent type expects a fraction, so normalize 0-100 -> 0-1.
            this.logs = data.map((row) => ({
                ...row,
                Batch_Success_Percentage__c:
                    row.Batch_Success_Percentage__c != null
                        ? row.Batch_Success_Percentage__c / 100
                        : null
            }));
            this.error = undefined;
        } else if (error) {
            this.error =
                (error.body && error.body.message) || error.message || 'Unknown error';
            this.logs = [];
        }
    }

    get hasLogs() {
        return this.logs && this.logs.length > 0;
    }

    handleRowAction(event) {
        if (event.detail.action.name === 'view_details') {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: event.detail.row.Id,
                    objectApiName: 'MAS_Log__c',
                    actionName: 'view'
                }
            });
        }
    }
}
