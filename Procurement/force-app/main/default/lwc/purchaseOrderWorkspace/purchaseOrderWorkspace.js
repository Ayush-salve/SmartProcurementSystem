import { LightningElement, api, track } from 'lwc';
import getPurchaseOrderWithLines from '@salesforce/apex/PurchaseOrderService.getPurchaseOrderWithLines';
import savePurchaseOrder from '@salesforce/apex/PurchaseOrderService.savePurchaseOrder';
import dispatchPurchaseOrder from '@salesforce/apex/PurchaseOrderService.dispatchPurchaseOrder';

export default class PurchaseOrderWorkspace extends LightningElement {
    @api recordId;
    @track order = {
        Order_Date__c: new Date().toISOString().split('T')[0],
        Status__c: 'Draft',
        Tax_Amount__c: 0,
        Shipping_Amount__c: 0
    };
    @track lines = [];
    @track isEditable = true;
    @track canDispatch = false;
    @track isLoading = false;
    @track isSaving = false;
    @track errorMessage = null;
    @track successMessage = null;

    _lineCounter = 0;

    connectedCallback() {
        if (this.recordId) this.loadPurchaseOrder();
    }

    loadPurchaseOrder() {
        this.isLoading = true;
        getPurchaseOrderWithLines({ poId: this.recordId })
            .then(wrapper => {
                this.order = { ...wrapper.order };
                this.lines = wrapper.lines.map(l => ({
                    ...l,
                    _key: l.Id,
                    productName: l.Product__r ? l.Product__r.Name : '',
                    lineTotal: (l.Quantity_Ordered__c || 0) * (l.Unit_Price__c || 0)
                }));
                this.isEditable = wrapper.isEditable;
                this.canDispatch = wrapper.canDispatch;
                this.isLoading = false;
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error loading purchase order';
                this.isLoading = false;
            });
    }

    handleFieldChange(event) {
        const field = event.currentTarget.dataset.field;
        this.order = { ...this.order, [field]: event.target.value };
    }

    handleAddLine() {
        this._lineCounter++;
        this.lines = [...this.lines, {
            _key: 'new-' + this._lineCounter,
            productName: '',
            Product__c: null,
            Quantity_Ordered__c: 1,
            Quantity_Received__c: 0,
            Unit_Price__c: 0,
            Line_Status__c: 'Open',
            lineTotal: 0
        }];
    }

    handleDeleteLine(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const updated = [...this.lines];
        updated.splice(idx, 1);
        this.lines = updated;
    }

    handleLineFieldChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const field = event.currentTarget.dataset.field;
        const updated = [...this.lines];
        updated[idx] = { ...updated[idx], [field]: parseFloat(event.target.value) || 0 };
        updated[idx].lineTotal = (updated[idx].Quantity_Ordered__c || 0) * (updated[idx].Unit_Price__c || 0);
        this.lines = updated;
    }

    handleSave() {
        this.errorMessage = null;
        this.successMessage = null;
        this.isSaving = true;
        const poData = { ...this.order, Subtotal__c: this.calculatedSubtotal };
        delete poData._key;
        const linesData = this.lines.map(l => {
            const line = { ...l };
            delete line._key;
            delete line.lineTotal;
            delete line.productName;
            return line;
        });
        savePurchaseOrder({ poJson: JSON.stringify(poData), linesJson: JSON.stringify(linesData) })
            .then(id => {
                this.order = { ...this.order, Id: id };
                this.successMessage = 'Purchase order saved.';
                this.isSaving = false;
                this.dispatchEvent(new CustomEvent('saved', { detail: { id } }));
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error saving purchase order';
                this.isSaving = false;
            });
    }

    handleDispatch() {
        const poId = this.order.Id || this.recordId;
        if (!poId) { this.errorMessage = 'Save the order first before dispatching.'; return; }
        if (!this.canDispatch) { this.errorMessage = 'Order must be Approved before dispatching.'; return; }
        this.isSaving = true;
        dispatchPurchaseOrder({ poId })
            .then(() => {
                this.successMessage = 'Purchase order dispatched successfully.';
                this.order = { ...this.order, Status__c: 'Sent' };
                this.canDispatch = false;
                this.isEditable = false;
                this.isSaving = false;
                this.dispatchEvent(new CustomEvent('dispatched', { detail: { id: poId } }));
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error dispatching order';
                this.isSaving = false;
            });
    }

    get calculatedSubtotal() {
        return this.lines.reduce((sum, l) => sum + (parseFloat(l.lineTotal) || 0), 0);
    }

    get calculatedTotal() {
        return this.calculatedSubtotal + (parseFloat(this.order.Tax_Amount__c) || 0) + (parseFloat(this.order.Shipping_Amount__c) || 0);
    }

    get orderStatus() { return this.order.Status__c || 'Draft'; }
    get isLocked() { return !this.isEditable; }
    get cardTitle() {
        return this.recordId ? 'Purchase Order — ' + (this.order.Name || '') : 'New Purchase Order';
    }
    get statusBadgeClass() {
        const s = this.orderStatus;
        if (s === 'Sent' || s === 'Received') return 'slds-badge_lightest';
        if (s === 'Cancelled') return 'slds-theme_error';
        return '';
    }
}
