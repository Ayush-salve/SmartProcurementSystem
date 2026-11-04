import { LightningElement, api, track } from 'lwc';
import getPurchaseOrderForReceipt from '@salesforce/apex/GoodsReceiptService.getPurchaseOrderForReceipt';
import saveGoodsReceipt from '@salesforce/apex/GoodsReceiptService.saveGoodsReceipt';
import postGoodsReceipt from '@salesforce/apex/GoodsReceiptService.postGoodsReceipt';

export default class GoodsReceiptForm extends LightningElement {
    @api recordId;
    @track selectedPoId = null;
    @track poSummary = null;
    @track receiptLines = [];
    @track linesLoaded = false;
    @track isLoading = false;
    @track isSaving = false;
    @track errorMessage = null;
    @track successMessage = null;
    @track isPosted = false;

    receiptDate = new Date().toISOString().split('T')[0];
    supplierRef = '';
    inspectionNotes = '';
    savedReceiptId = null;

    rejectionReasonOptions = [
        { label: '— Select Reason —', value: '' },
        { label: 'Damage', value: 'Damage' },
        { label: 'Wrong Item', value: 'Wrong Item' },
        { label: 'Quality Failure', value: 'Quality Failure' },
        { label: 'Other', value: 'Other' }
    ];

    connectedCallback() {
        if (this.recordId) {
            this.selectedPoId = this.recordId;
            this.loadPoLines();
        }
    }

    handlePoChange(event) {
        this.selectedPoId = event.detail.recordId;
        this.linesLoaded = false;
        this.receiptLines = [];
        this.poSummary = null;
    }

    loadPoLines() {
        if (!this.selectedPoId) return;
        this.isLoading = true;
        this.errorMessage = null;
        getPurchaseOrderForReceipt({ poId: this.selectedPoId })
            .then(data => {
                this.poSummary = {
                    supplierName: data.po.Supplier__r ? data.po.Supplier__r.Name : '',
                    warehouseName: data.po.Warehouse__r ? data.po.Warehouse__r.Name : '',
                    status: data.po.Status__c
                };
                this.receiptLines = data.lines.map(l => ({
                    ...l,
                    quantityDelivered: l.remaining,
                    quantityAccepted: l.remaining,
                    quantityRejected: 0,
                    rejectionReason: '',
                    batchNumber: '',
                    hasRejected: false,
                    rowClass: l.remaining <= 0 ? 'slds-theme_shade' : ''
                }));
                this.linesLoaded = true;
                this.isLoading = false;
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error loading PO lines';
                this.isLoading = false;
            });
    }

    handleReceiptDateChange(event) { this.receiptDate = event.target.value; }
    handleSupplierRefChange(event) { this.supplierRef = event.target.value; }
    handleInspectionNotesChange(event) { this.inspectionNotes = event.target.value; }

    handleLineQtyChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const field = event.currentTarget.dataset.field;
        const val = parseFloat(event.target.value) || 0;
        const updated = [...this.receiptLines];
        updated[idx] = { ...updated[idx], [field]: val };
        updated[idx].hasRejected = (updated[idx].quantityRejected || 0) > 0;
        this.receiptLines = updated;
    }

    handleLineSelectChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const field = event.currentTarget.dataset.field;
        const updated = [...this.receiptLines];
        updated[idx] = { ...updated[idx], [field]: event.detail.value };
        this.receiptLines = updated;
    }

    handleLineTextChange(event) {
        const idx = parseInt(event.currentTarget.dataset.idx, 10);
        const field = event.currentTarget.dataset.field;
        const updated = [...this.receiptLines];
        updated[idx] = { ...updated[idx], [field]: event.target.value };
        this.receiptLines = updated;
    }

    get noPoSelected() { return !this.selectedPoId; }
    get totalAccepted() { return this.receiptLines.reduce((s, l) => s + (l.quantityAccepted || 0), 0); }

    validateLines() {
        for (const line of this.receiptLines) {
            const del = line.quantityDelivered || 0;
            const acc = line.quantityAccepted || 0;
            const rej = line.quantityRejected || 0;
            if (acc + rej > del) {
                this.errorMessage = `Line "${line.productName}": Accepted + Rejected cannot exceed Delivered.`;
                return false;
            }
            if (acc < 0 || rej < 0 || del < 0) {
                this.errorMessage = 'Quantities cannot be negative.';
                return false;
            }
        }
        return true;
    }

    buildReceiptAndLines() {
        const receipt = {
            Purchase_Order__c: this.selectedPoId,
            Receipt_Date__c: this.receiptDate,
            Supplier_Delivery_Reference__c: this.supplierRef,
            Inspection_Notes__c: this.inspectionNotes,
            Status__c: 'Inspecting'
        };
        if (this.savedReceiptId) receipt.Id = this.savedReceiptId;
        const lines = this.receiptLines.map(l => ({
            Purchase_Order_Line__c: l.polId,
            Quantity_Delivered__c: l.quantityDelivered || 0,
            Quantity_Accepted__c: l.quantityAccepted || 0,
            Quantity_Rejected__c: l.quantityRejected || 0,
            Rejection_Reason__c: l.rejectionReason || null,
            Batch_Number__c: l.batchNumber || null
        }));
        return { receipt, lines };
    }

    handleSave() {
        this.errorMessage = null;
        this.successMessage = null;
        if (!this.validateLines()) return;
        this.isSaving = true;
        const { receipt, lines } = this.buildReceiptAndLines();
        saveGoodsReceipt({ receiptJson: JSON.stringify(receipt), linesJson: JSON.stringify(lines) })
            .then(id => {
                this.savedReceiptId = id;
                this.successMessage = 'Receipt saved. Ready to post.';
                this.isSaving = false;
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error saving receipt';
                this.isSaving = false;
            });
    }

    handlePost() {
        this.errorMessage = null;
        this.successMessage = null;
        if (!this.validateLines()) return;
        this.isSaving = true;
        const saveAndPost = () => {
            const { receipt, lines } = this.buildReceiptAndLines();
            return saveGoodsReceipt({ receiptJson: JSON.stringify(receipt), linesJson: JSON.stringify(lines) })
                .then(id => {
                    this.savedReceiptId = id;
                    return postGoodsReceipt({ receiptId: id });
                });
        };
        const postAction = this.savedReceiptId
            ? postGoodsReceipt({ receiptId: this.savedReceiptId })
            : saveAndPost();
        postAction
            .then(() => {
                this.successMessage = 'Receipt posted! Inventory has been updated.';
                this.isPosted = true;
                this.isSaving = false;
                this.dispatchEvent(new CustomEvent('posted', { detail: { receiptId: this.savedReceiptId } }));
            })
            .catch(err => {
                this.errorMessage = err.body ? err.body.message : 'Error posting receipt';
                this.isSaving = false;
            });
    }
}
