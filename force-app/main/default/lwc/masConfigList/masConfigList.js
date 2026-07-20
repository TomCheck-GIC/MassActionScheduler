import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

/**
 * Simple entry-point component for the Mass Action Scheduler app.
 * Provides a "New Configuration" action that navigates to the standard
 * create page for MAS_Configuration__c. Individual configurations are
 * managed from their own record pages (via masConfigWizard).
 */
export default class MasConfigList extends NavigationMixin(LightningElement) {
    handleNew() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'MAS_Configuration__c',
                actionName: 'new'
            }
        });
    }

    handleViewAll() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'MAS_Configuration__c',
                actionName: 'list'
            },
            state: {
                filterName: 'Recent'
            }
        });
    }
}
