import { LightningElement, track, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getMatrixCsvData from '@salesforce/apex/CsvDataController.getMatrixCsvData';
import searchMatrixCsvData from '@salesforce/apex/CsvDataController.searchMatrixCsvData'; // Add this import
import getMatrixVersions from '@salesforce/apex/CsvDataController.getMatrixVersions';
import deleteMatrixVersion from '@salesforce/apex/CsvDataController.deleteMatrixVersion';
import toggleMatrixVersion from '@salesforce/apex/CsvDataController.toggleMatrixVersion';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import NAME_FIELD from '@salesforce/schema/vlocity_ins__CalculationMatrix__c.Name';
import previewCsvData from '@salesforce/apex/CsvDataController.previewCsvData';
import saveMatrixVersion from '@salesforce/apex/CsvDataController.saveMatrixVersion';
import enableOnlySelectedMatrixVersion from '@salesforce/apex/CsvDataController.enableOnlySelectedMatrixVersion';
// Add these imports
import updateMatrixData from '@salesforce/apex/CsvDataController.updateMatrixData';
import saveUpdatedPreviewAsVersion from '@salesforce/apex/CsvDataController.saveUpdatedPreviewAsVersion';

export default class CsvDataViewer extends LightningElement {
    // Public properties for Vlocity context
    @api calculationMatrixId; // Can be passed from parent component
    @api defaultMatrixName = 'Pricing_Matrix';
    @api recordId;
    
    // Add a property to store the record name
    @track recordName = '';
    
    // File management
    @track matrixVersionId = '';
    @track selectedVersionId = '';
    @track fileName = '';
    @track hasUploadedFile = false;
    @track matrixName = '';
    @track isMatrixEnabled = false;
    
    // Version management
    @track matrixVersions = [];
    @track showVersionDropdown = false;
    
    // Data management
    // Initialize table properties with safe defaults
    @track tableData = [];
    @track tableColumns = [];
    @track totalRecords = 0;
    
    // Pagination
    @track currentPage = 1;
    @track pageSize = '25';
    @track totalPages = 0;
    
    // UI state
    @track isLoading = false;
    @track errorMessage = '';
    @track sortedBy = '';
    @track sortedDirection = 'asc';
    @track showMatrixNameInput = false;
    
    // Page size options
    @track pageSizeOptions = [
        { label: '25', value: '25' },
        { label: '50', value: '50' },
        { label: '100', value: '100' },
        { label: '200', value: '200' }
    ];
    // Add search-related properties
    @track searchTerm = '';
    @track isSearchActive = false;
    @track searchDebounceTimeout;

    // Add new properties for CSV preview
    @track csvPreviewData = null;
    @track uploadedFileContent = '';
    @track uploadedFileName = '';
    @track showPreview = false;
    @track isReadyToSave = false;
    // Add this property for storing all preview data
    @track allPreviewData = [];
    // Add new properties for inline editing
    @track isInEditMode = false;
    @track draftValues = [];
    @track hasUnsavedChanges = false;
    @track editedRowsCount = 0;

    // Add new properties for column configuration
    @track showColumnConfig = false;
    @track columnConfigurations = [];
    @track headers = [];

    // Add these properties after the existing track properties
    headerTypeOptions = [
        { label: 'Input', value: 'Input' },
        { label: 'Output', value: 'Output' }
    ];

    dataTypeOptions = [
        { label: 'Text', value: 'Text' },
        { label: 'Number', value: 'Number' },
        { label: 'Percent', value: 'Percent' },
        { label: 'Currency', value: 'Currency' },
        { label: 'Date', value: 'Date' },
        { label: 'Boolean', value: 'Boolean' }
    ];
    
    /**
     * Wire method to get matrix versions when recordId changes
     */
    @wire(getMatrixVersions, { calculationMatrixId: '$effectiveMatrixId' })
    wiredMatrixVersions({ error, data }) {
        if (data) {
            this.matrixVersions = data.map(version => ({
                label: version.label,
                value: version.value
            }));
            this.showVersionDropdown = this.matrixVersions.length > 0;
            
        } else if (error) {
            console.error('Error loading matrix versions:', error);
            this.matrixVersions = [];
            this.showVersionDropdown = false;
        }
    }
    /**
     * Wire service to get the current record
     */
    @wire(getRecord, { recordId: '$recordId', fields: [NAME_FIELD] })
    wiredRecord({ error, data }) {
        if (data) {
            this.recordName = getFieldValue(data, NAME_FIELD);
            this.matrixName = this.recordName || this.defaultMatrixName;
        } else if (error) {
            console.error('Error loading record:', error);
            this.matrixName = this.defaultMatrixName;
        }
    }
    /**
     * Computed properties
     */
    get effectiveMatrixId() {
        return this.calculationMatrixId || this.recordId;
    }
    get hasData() {
    // Always show data area in preview mode, even if no results
        return this.hasUploadedFile || this.showPreview;
    }
    get hasVersions() {
        return this.matrixVersions.length > 0;
    }
    // Add this new computed property
    get showUploadSection() {
        // Show upload section if no versions exist OR user hasn't selected a version yet
        return !this.hasVersions || (!this.selectedVersionId && !this.hasUploadedFile);
    }
    // Update existing computed property
    get showUploadNewButton() {
        // Only show "Upload New Version" button when viewing existing data
        return this.hasUploadedFile && this.selectedVersionId;
    }
    get isFirstPage() {
        return this.currentPage <= 1;
    }
    get isLastPage() {
        return this.currentPage >= this.totalPages;
    }
    get startRecord() {
        if (this.totalRecords === 0) return 0;
        const numericPageSize = parseInt(this.pageSize);
        return ((this.currentPage - 1) * numericPageSize) + 1;
    }
    get endRecord() {
        const numericPageSize = parseInt(this.pageSize);
        const end = this.currentPage * numericPageSize;
        return end > this.totalRecords ? this.totalRecords : end;
    }
    get enableToggleLabel() {
        return this.isMatrixEnabled ? 'Disable Matrix' : 'Enable Matrix';
    }
    get enableToggleVariant() {
        return 'border-inverse';
    }
    // Add new computed properties for search
    get showSearchResults() {
        return this.isSearchActive && this.searchTerm;
    }
    get searchResultsText() {
        if (this.isSearchActive && this.searchTerm) {
            const dataSource = this.showPreview ? 'preview data' : 'matrix data';
            return `Search results for "${this.searchTerm}" in ${dataSource} (${this.totalRecords} found)`;
        }
        return '';
    }
    // Add this computed property for no search results
    get isNoSearchResults() {
        return this.isSearchActive && this.searchTerm && this.tableData.length === 0;
    }
    get showSaveVersionButton() {
        return this.isReadyToSave && this.csvPreviewData && !this.hasUploadedFile;
    }

    get dataTableTitle() {
        return this.showPreview ? 'CSV Preview (All Rows)' : 'Matrix Data';
    }

    // New computed property for column configuration
    get showConfigureColumnsButton() {
        return this.showPreview && this.headers && this.headers.length > 0;
    }
    /**
     * Component lifecycle
     */
    connectedCallback() {
        // Initialize with empty but valid table columns to prevent render errors
        this.tableColumns = [];
        this.tableData = [];
    }
    /**
     * Event Handlers
     */
    
    /**
     * Handle version selection change
     */
    async handleVersionChange(event) {
        try {
            this.selectedVersionId = event.detail.value;
            await this.loadSelectedVersion();
        } catch (error) {
            console.error('Error loading selected version:', error);
            this.showToast('Error', 'Error loading selected version: ' + (error.body?.message || error.message), 'error');
        }
    }
    /**
     * Load data for the selected version
     */
    async loadSelectedVersion() {
        if (!this.selectedVersionId) return;
        
        try {
            this.isLoading = true;
            this.matrixVersionId = this.selectedVersionId;
            this.hasUploadedFile = true;
            this.currentPage = 1; // Reset to first page
            await this.loadMatrixData();
        } catch (error) {
            console.error('Error loading selected version:', error);
            this.showToast('Error', 'Error loading version data: ' + (error.body?.message || error.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }
    /**
     * Handle matrix name input change
     */
    handleMatrixNameChange(event) {
        this.matrixName = event.target.value;
    }
    /**
     * Handle file upload using standard file input
     */
    handleFileChange(event) {
        const files = event.target.files;
        if (files.length > 0) {
            this.processFile(files[0]);
        }
    }
    /**
     * Read file as Base64 string
     */
    readFileAsBase64(file) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                // Get the base64 string without the data URL prefix
                const base64 = reader.result.split(',')[1];
                resolve(base64);
            };
            reader.onerror = () => {
                reject(new Error('Error reading file'));
            };
            reader.readAsDataURL(file);
        });
    }

    /**
     * Process the selected file - Now only previews, doesn't create version
     */
    async processFile(file) {
        try {
            this.isLoading = true;
            this.errorMessage = '';
            
            // Validate file type
            if (!file.name.toLowerCase().endsWith('.csv')) {
                this.showToast('Error', 'Only CSV files are allowed.', 'error');
                return;
            }
            
            // Validate file size
            if (file.size > 5 * 1024 * 1024) { // 5MB
                this.showToast('Error', 'File size exceeds 5MB limit.', 'error');
                return;
            }
            
            // Read file content
            const fileContent = await this.readFileAsBase64(file);
            
            console.log('Processing file for preview:', file.name);
            
            // Store file data for later use
            this.uploadedFileContent = fileContent;
            this.uploadedFileName = file.name;
            
            // Preview CSV data instead of creating version immediately
            const previewResponse = await previewCsvData({
                fileName: file.name,
                fileContent: fileContent
            });
            
            if (previewResponse.isValid) {
                this.csvPreviewData = previewResponse;
                this.showPreview = true;
                this.isReadyToSave = true;
                
                // Store all preview data for pagination
                this.allPreviewData = previewResponse.previewRecords || [];
                this.totalRecords = previewResponse.totalDataRows || 0;
                this.currentPage = 1; // Reset to first page for preview
                
                // Generate preview columns for display
                if (previewResponse.headers && previewResponse.headers.length > 0) {
                    this.headers = [...previewResponse.headers]; // Store headers for column config
                    this.generateTableColumns(previewResponse.headers);
                    
                    // Initialize column configurations with defaults
                    this.columnConfigurations = this.headers.map(header => ({
                        name: header,
                        headerType: 'Input', // Default to Input
                        dataType: 'Text'     // Default to Text
                    }));
                    
                    // Apply pagination to preview data
                    this.applyPreviewPagination();
                }
                
                this.showToast('Success', `CSV file loaded successfully! Preview shows ${previewResponse.totalDataRows} data rows. Configure columns and click "Save this Matrix Version" to save.`, 'success');
                
                // Show column configuration modal automatically
                this.showColumnConfig = true;
            } else {
                this.errorMessage = previewResponse.errorMessage || 'Error previewing CSV file.';
                this.showToast('Preview Error', this.errorMessage, 'error');
            }
            
        } catch (error) {
            console.error('Preview error:', error);
            this.errorMessage = error.body?.message || error.message || 'Unknown error occurred during preview.';
            this.showToast('Preview Error', this.errorMessage, 'error');
        } finally {
            this.isLoading = false;
        }
    }
    /**
     * Handle Save Matrix Version button click
     */
    async handleSaveMatrixVersion() {
        try {
            this.isLoading = true;
            this.errorMessage = '';
            
            if (!this.uploadedFileContent || !this.uploadedFileName) {
                this.showToast('Error', 'No file data available to save.', 'error');
                return;
            }
            // Use calculationMatrixId if provided, otherwise use recordId
            const matrixId = this.calculationMatrixId || this.recordId;
            
            console.log('Saving matrix version:', this.uploadedFileName);
            console.log('Matrix name:', this.matrixName);
            console.log('Calculation Matrix ID:', matrixId);
            console.log('Column configurations:', this.columnConfigurations);
            
            // Check if user has made any edits to the preview data
            if (this.hasUnsavedChanges) {
                // First save the edits to the preview data
                await this.savePreviewEdits();
            }
            
            // If we have edited preview data, use that instead of the original file
            if (this.allPreviewData && this.allPreviewData.length > 0 && this.csvPreviewData && this.csvPreviewData.headers) {
                console.log('Saving with edited preview data');
                
                // Use saveUpdatedPreviewAsVersion which handles edited data
                this.matrixVersionId = await saveUpdatedPreviewAsVersion({
                    fileName: this.uploadedFileName,
                    updatedRecords: this.allPreviewData,
                    headers: this.csvPreviewData.headers,
                    matrixName: this.matrixName,
                    calculationMatrixId: matrixId,
                    columnConfigs: this.columnConfigurations
                });
            } else {
                // Fall back to original file content if no preview data is available
                console.log('Saving with original file content');
                
                // Save using original file content
                this.matrixVersionId = await saveMatrixVersion({
                    fileName: this.uploadedFileName,
                    fileContent: this.uploadedFileContent,
                    matrixName: this.matrixName,
                    calculationMatrixId: matrixId,
                    columnConfigs: this.columnConfigurations
                });
            }
            
            this.fileName = this.uploadedFileName;
            this.hasUploadedFile = true;
            this.showMatrixNameInput = false;
            this.selectedVersionId = this.matrixVersionId;
            this.showPreview = false;
            this.isReadyToSave = false;
            this.showColumnConfig = false;
            
            // Clear editing state
            this.draftValues = [];
            this.hasUnsavedChanges = false;
            this.editedRowsCount = 0;
            
            // Clear temporary data
            this.csvPreviewData = null;
            this.uploadedFileContent = '';
            this.uploadedFileName = '';
            this.allPreviewData = [];
            
            console.log('Created Matrix Version ID:', this.matrixVersionId);
            
            // Load first page of data
            await this.loadMatrixData();
            
            this.showToast('Success', `Matrix Version saved successfully with your edits!`, 'success');
        } catch (error) {
            console.error('Save version error:', error);
            this.errorMessage = error.body?.message || error.message || 'Unknown error occurred while saving version.';
            this.showToast('Save Error', this.errorMessage, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Handle cancel preview
     */
    handleCancelPreview() {
        this.csvPreviewData = null;
        this.uploadedFileContent = '';
        this.uploadedFileName = '';
        this.showPreview = false;
        this.isReadyToSave = false;
        this.allPreviewData = [];
        this.tableData = [];
        this.tableColumns = [];
        this.totalRecords = 0;
        this.currentPage = 1;
        this.totalPages = 0;
        this.showColumnConfig = false;
        this.columnConfigurations = [];
        this.headers = [];
        
        // Clear search state
        this.searchTerm = '';
        this.isSearchActive = false;
        
        // Reset file input
        const fileInput = this.template.querySelector('#file-upload');
        if (fileInput) {
            fileInput.value = '';
        }
    }

    /**
     * Apply pagination to preview data
     */
    applyPreviewPagination() {
        if (!this.allPreviewData || this.allPreviewData.length === 0) {
            this.tableData = [];
            this.totalPages = 0;
            return;
        }
        
        // Convert pageSize to number for calculations
        const numericPageSize = parseInt(this.pageSize);
        
        // Calculate pagination
        this.totalPages = Math.ceil(this.totalRecords / numericPageSize);
        const startIndex = (this.currentPage - 1) * numericPageSize;
        const endIndex = Math.min(startIndex + numericPageSize, this.allPreviewData.length);
        
        // Get current page data
        this.tableData = this.allPreviewData.slice(startIndex, endIndex);
        
        // Update row numbers for current page
        this.tableData.forEach((record, index) => {
            record.rowNumber = startIndex + index + 1;
        });
    }

    // Update pagination handlers to work with preview data
    async handleFirstPage() {
        this.currentPage = 1;
        if (this.showPreview) {
            if (this.isSearchActive) {
                this.performPreviewSearch();
            } else {
                this.applyPreviewPagination();
            }
        } else if (this.isSearchActive) {
            await this.loadSearchResults();
        } else {
            await this.loadMatrixData();
        }
    }

    async handlePreviousPage() {
        if (this.currentPage > 1) {
            this.currentPage--;
            if (this.showPreview) {
                if (this.isSearchActive) {
                    this.performPreviewSearch();
                } else {
                    this.applyPreviewPagination();
                }
            } else if (this.isSearchActive) {
                await this.loadSearchResults();
            } else {
                await this.loadMatrixData();
            }
        }
    }

    async handleNextPage() {
        if (this.currentPage < this.totalPages) {
            this.currentPage++;
            if (this.showPreview) {
                if (this.isSearchActive) {
                    this.performPreviewSearch();
                } else {
                    this.applyPreviewPagination();
                }
            } else if (this.isSearchActive) {
                await this.loadSearchResults();
            } else {
                await this.loadMatrixData();
            }
        }
    }

    async handleLastPage() {
        this.currentPage = this.totalPages;
        if (this.showPreview) {
            if (this.isSearchActive) {
                this.performPreviewSearch();
            } else {
                this.applyPreviewPagination();
            }
        } else if (this.isSearchActive) {
            await this.loadSearchResults();
        } else {
            await this.loadMatrixData();
        }
    }

    async handlePageSizeChange(event) {
        this.pageSize = event.detail.value; // Keep as string
        this.currentPage = 1; // Reset to first page
        
        // Convert to number for calculations
        const numericPageSize = parseInt(this.pageSize);
        
        if (this.showPreview) {
            if (this.isSearchActive) {
                this.performPreviewSearch();
            } else {
                this.applyPreviewPagination();
            }
        } else if (this.isSearchActive) {
            await this.loadSearchResults();
        } else {
            await this.loadMatrixData();
        }
    }

    async handlePageNumberChange(event) {
        const newPage = parseInt(event.detail.value);
        if (newPage >= 1 && newPage <= this.totalPages) {
            this.currentPage = newPage;
            if (this.showPreview) {
                if (this.isSearchActive) {
                    this.performPreviewSearch();
                } else {
                    this.applyPreviewPagination();
                }
            } else if (this.isSearchActive) {
                await this.loadSearchResults();
            } else {
                await this.loadMatrixData();
            }
        }
    }

    /**
     * Business Logic Methods
     */
    /**
     * Load CSV data from Calculation Matrix Version
     */
    async loadMatrixData() {
        try {
            this.isLoading = true;
            this.errorMessage = '';
            console.log('Loading Matrix CSV data with:', {
                matrixVersionId: this.matrixVersionId,
                pageNumber: this.currentPage,
                pageSize: parseInt(this.pageSize) // Convert to number for API call
            });
            const response = await getMatrixCsvData({
                matrixVersionId: this.matrixVersionId,
                pageNumber: this.currentPage,
                pageSize: parseInt(this.pageSize) // Convert to number for API call
            });
            console.log('Matrix CSV data response:', response);
            this.tableData = response.records || [];
            this.totalRecords = response.totalRecords || 0;
            this.totalPages = response.totalPages || 0;
            this.fileName = response.fileName || this.fileName;
            this.isMatrixEnabled = response.isEnabled || false;
            // Generate columns from headers
            if (response.headers && response.headers.length > 0) {
                this.generateTableColumns(response.headers);
            }
            // Apply sorting if any
            if (this.sortedBy) {
                this.tableData = this.sortData(this.tableData, this.sortedBy, this.sortedDirection);
            }
        } catch (error) {
            console.error('Load matrix data error:', error);
            this.errorMessage = error.body?.message || error.message || 'Error loading matrix CSV data.';
            this.showToast('Load Error', this.errorMessage, 'error');
        } finally {
            this.isLoading = false;
        }
    }
    /**
     * Generate table columns from CSV headers with optimal widths
     */
    generateTableColumns(headers) {
        // Add safety check
        if (!headers || !Array.isArray(headers) || headers.length === 0) {
            console.warn('Invalid headers provided to generateTableColumns');
            this.tableColumns = [];
            return;
        }
        
        const columns = [
            {
                label: '#',
                fieldName: 'rowNumber',
                type: 'number',
                fixedWidth: 60,
                sortable: false,
                editable: false // Row number should not be editable
            }
        ];
        
        headers.forEach((header, index) => {
            // Add safety checks for header
            if (!header || typeof header !== 'string') {
                console.warn(`Invalid header at index ${index}:`, header);
                return; // Skip this header
            }
            const fieldName = this.sanitizeFieldName(header);
            
            // Safe width calculation with bounds checking
            let columnWidth;
            try {
                // Ensure header.length exists and is a number
                const headerLength = header && typeof header === 'string' ? header.length : 10;
                columnWidth = Math.max(120, Math.min(250, headerLength * 8 + 40));
                
                // Additional safety check
                if (isNaN(columnWidth) || columnWidth < 60) {
                    columnWidth = 150; // Default fallback width
                }
            } catch (error) {
                console.error('Error calculating column width:', error);
                columnWidth = 150; // Default fallback width
            }
            
            columns.push({
                label: header,
                fieldName: fieldName,
                type: 'text',
                sortable: true,
                editable: true, // Enable inline editing for data columns
                wrapText: false,
                fixedWidth: columnWidth,
                cellAttributes: {
                    alignment: 'left'
                }
            });
        });
        
        this.tableColumns = columns;
    }
    /**
     * Sort data array
     */
    sortData(data, fieldName, direction) {
        const isReverse = direction === 'desc';
        
        return [...data].sort((a, b) => {
            let aVal = a[fieldName] || '';
            let bVal = b[fieldName] || '';
            
            // Convert to string for comparison
            aVal = String(aVal).toLowerCase();
            bVal = String(bVal).toLowerCase();
            
            if (aVal < bVal) {
                return isReverse ? 1 : -1;
            }
            if (aVal > bVal) {
                return isReverse ? -1 : 1;
            }
            return 0;
        });
    }
    /**
     * Utility Methods
     */
    /**
     * Sanitize field names for use as map keys
     */
    sanitizeFieldName(fieldName) {
        // Add more robust safety checks
        if (!fieldName || typeof fieldName !== 'string') {
            return 'Column_' + Date.now(); // Unique fallback name
        }
        
        // Remove special characters and spaces, replace with underscores
        let sanitized = fieldName.replace(/[^a-zA-Z0-9]/g, '_');
        
        // Ensure it starts with a letter
        if (!/^[a-zA-Z]/.test(sanitized)) {
            sanitized = 'Col_' + sanitized;
        }
        
        // Ensure it's not empty after sanitization
        if (!sanitized || sanitized === '_') {
            sanitized = 'Column_' + Date.now();
        }
        
        return sanitized;
    }
    /**
     * Reset component to initial state
     */
    resetComponent() {
        this.matrixVersionId = '';
        this.selectedVersionId = '';
        this.fileName = '';
        this.hasUploadedFile = false;
        this.tableData = [];
        this.tableColumns = [];
        this.totalRecords = 0;
        this.currentPage = 1;
        this.totalPages = 0;
        this.errorMessage = '';
        this.sortedBy = '';
        this.sortedDirection = 'asc';
        this.isMatrixEnabled = false;
        this.showMatrixNameInput = false;
        this.searchTerm = '';
        this.isSearchActive = false;
        
        // Reset preview data
        this.csvPreviewData = null;
        this.uploadedFileContent = '';
        this.uploadedFileName = '';
        this.showPreview = false;
        this.isReadyToSave = false;
        this.allPreviewData = [];
        this.showColumnConfig = false;
        this.columnConfigurations = [];
        this.headers = [];
        
        // Use the record name if available, otherwise use default
        this.matrixName = this.recordName || this.defaultMatrixName;
    }
    /**
     * Show toast message
     */
    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant
        });
        this.dispatchEvent(event);
    }
    /**
     * Handle upload new version button
     */
    handleUploadNewVersion() {
        this.hasUploadedFile = false;
        this.resetComponent();
    }

    /**
     * Handle search input change with debouncing
     */
    handleSearchChange(event) {
        const searchValue = event.target.value;
        this.searchTerm = searchValue;
        
        // Clear existing timeout
        if (this.searchDebounceTimeout) {
            clearTimeout(this.searchDebounceTimeout);
        }
        
        // Debounce search - wait 500ms after user stops typing
        this.searchDebounceTimeout = setTimeout(() => {
            this.performSearch();
        }, 500);
    }

    /**
     * Handle search button click
     */
    handleSearchClick() {
        this.performSearch();
    }

    /**
     * Handle clear search
     */
    handleClearSearch() {
        this.searchTerm = '';
        this.isSearchActive = false;
        this.currentPage = 1; // Reset to first page
        
        if (this.showPreview) {
            // Reset to full preview data
            this.totalRecords = this.allPreviewData.length;
            this.applyPreviewPagination();
        } else if (this.matrixVersionId) {
            // Load all matrix data without search
            this.loadMatrixData();
        }
    }

    /**
     * Handle search on Enter key press
     */
    handleSearchKeyPress(event) {
        if (event.key === 'Enter') {
            event.preventDefault();
            this.performSearch();
        }
    }

    /**
     * Perform the search - Updated to handle preview data
     */
    async performSearch() {
        try {
            this.isLoading = true;
            this.currentPage = 1; // Reset to first page for search results
            
            // Check if we have search term
            if (this.searchTerm && this.searchTerm.trim() !== '') {
                this.isSearchActive = true;
                
                // If in preview mode, search preview data locally
                if (this.showPreview && this.allPreviewData) {
                    this.performPreviewSearch();
                } else if (this.matrixVersionId) {
                    // If saved matrix version, search on server
                    await this.loadSearchResults();
                } else {
                    console.warn('No data available for search');
                    this.showToast('Info', 'No data available for search', 'info');
                }
            } else {
                this.isSearchActive = false;
                
                // Load appropriate data based on mode
                if (this.showPreview) {
                    this.applyPreviewPagination();
                } else if (this.matrixVersionId) {
                    await this.loadMatrixData();
                }
            }
        } catch (error) {
            console.error('Search error:', error);
            this.showToast('Search Error', 'Error performing search: ' + (error.body?.message || error.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    /**
     * Perform search on preview data locally
     */
    performPreviewSearch() {
        if (!this.allPreviewData || this.allPreviewData.length === 0) {
            this.tableData = [];
            this.totalRecords = 0;
            this.totalPages = 0;
            return;
        }
        
        const searchTerm = this.searchTerm.toLowerCase().trim();
        const numericPageSize = parseInt(this.pageSize); // Convert to number
        
        // Filter preview data based on search term
        const filteredData = this.allPreviewData.filter(record => {
            // Search across all fields in the record
            return Object.values(record).some(value => {
                if (value === null || value === undefined) return false;
                return String(value).toLowerCase().includes(searchTerm);
            });
        });
        
        console.log(`Preview search: Found ${filteredData.length} matches for "${searchTerm}"`);
        
        // Update totals for filtered data
        this.totalRecords = filteredData.length;
        this.totalPages = Math.ceil(this.totalRecords / numericPageSize);
        
        // Apply pagination to filtered data
        const startIndex = (this.currentPage - 1) * numericPageSize;
        const endIndex = Math.min(startIndex + numericPageSize, filteredData.length);
        
        this.tableData = filteredData.slice(startIndex, endIndex);
        
        // Update row numbers for current page of filtered data
        this.tableData.forEach((record, index) => {
            record.rowNumber = startIndex + index + 1;
        });
        
        // Show search results message
        if (filteredData.length === 0) {
            this.showToast('Info', `No results found for "${this.searchTerm}"`, 'info');
        } else {
            this.showToast('Success', `Found ${filteredData.length} results for "${this.searchTerm}"`, 'success');
        }
    }

    /**
     * Load search results from server for saved matrix version
     */
    async loadSearchResults() {
        try {
            this.isLoading = true;
            this.errorMessage = '';
            // Add safety check
            if (!this.matrixVersionId) {
                console.warn('No matrixVersionId available for search');
                return;
            }
            const response = await searchMatrixCsvData({
                matrixVersionId: this.matrixVersionId,
                searchTerm: this.searchTerm,
                pageNumber: this.currentPage,
                pageSize: parseInt(this.pageSize) // Convert to number for API call
            });
            this.tableData = response?.records || [];
            this.totalRecords = response?.totalRecords || 0;
            this.totalPages = response?.totalPages || 0;
            this.fileName = response?.fileName || this.fileName || '';
            this.isMatrixEnabled = response?.isEnabled || false;
            // Generate columns from headers with safety check
            if (response?.headers && Array.isArray(response.headers) && response.headers.length > 0) {
                this.generateTableColumns(response.headers);
            } else {
                this.tableColumns = [];
            }
            // Apply sorting if any
            if (this.sortedBy && this.tableData.length > 0) {
                this.tableData = this.sortData(this.tableData, this.sortedBy, this.sortedDirection);
            }
        } catch (error) {
            console.error('Load search results error:', error);
            this.errorMessage = error.body?.message || error.message || 'Error loading search results.';
            this.showToast('Search Error', this.errorMessage, 'error');
            // Reset data on error
            this.tableData = [];
            this.tableColumns = [];
            this.totalRecords = 0;
            this.totalPages = 0;
        } finally {
            this.isLoading = false;
        }
    }

    // Add event handlers for inline editing
    handleCellChange(event) {
        console.log('Cell change event triggered:', event.detail);
        
        // Get the new draft values from the event
        const newDraftValues = event.detail.draftValues;
        console.log('New draft values from event:', newDraftValues);
        
        // Merge with existing draft values instead of replacing
        const mergedDraftValues = this.mergeDraftValues(this.draftValues, newDraftValues);
        
        // Update tracked properties
        this.draftValues = [...mergedDraftValues]; // Create new array to trigger reactivity
        this.hasUnsavedChanges = this.draftValues.length > 0;
        this.editedRowsCount = this.draftValues.length;
        
        console.log('Merged draft values:', this.draftValues);
        console.log('Updated state:', {
            draftValues: this.draftValues,
            hasUnsavedChanges: this.hasUnsavedChanges,
            editedRowsCount: this.editedRowsCount
        });
    }

    handleSaveEdits() {
        if (!this.hasUnsavedChanges) {
            this.showToast('Info', 'No changes to save.', 'info');
            return;
        }
        
        if (this.showPreview) {
            this.savePreviewEdits();
        } else {
            this.saveMatrixEdits();
        }
    }

    async savePreviewEdits() {
        try {
            this.isLoading = true; 
            
            // Apply draft values to preview data
            const updatedData = this.applyDraftValuesToData([...this.allPreviewData]);
            this.allPreviewData = updatedData;
            
            // Refresh current page display
            this.applyPreviewPagination();
            
            // Clear draft values
            this.draftValues = [];
            this.hasUnsavedChanges = false;
            this.editedRowsCount = 0;
            
            this.showToast('Success', 'Preview data updated successfully. Remember to save the matrix version to persist changes.', 'success');
            
        } catch (error) {
            console.error('Error saving preview edits:', error);
            this.showToast('Error', 'Error saving preview edits: ' + (error.body?.message || error.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async saveMatrixEdits() {
        try {
            this.isLoading = true;
            
            // Get all the records that have been edited
            const editedRecords = [];
            
            if (this.draftValues && this.draftValues.length > 0) {
                // Create a map for quick lookup of current page data
                const currentPageMap = new Map();
                this.tableData.forEach(record => {
                    const rowNumber = parseInt(record.rowNumber);
                    currentPageMap.set(rowNumber, record);
                });
                
                // Process each draft value
                this.draftValues.forEach(draft => {
                    const rowNumber = parseInt(draft.rowNumber);
                    const originalRecord = currentPageMap.get(rowNumber);
                    
                    if (originalRecord) {
                        // Create updated record with draft values applied
                        const updatedRecord = { ...originalRecord };
                        Object.keys(draft).forEach(key => {
                            if (key !== 'rowNumber') {
                                updatedRecord[key] = draft[key];
                            }
                        });
                        updatedRecord.rowNumber = rowNumber;
                        editedRecords.push(updatedRecord);
                    }
                });
            }
            
            console.log('Records to update:', editedRecords);
            
            if (editedRecords.length === 0) {
                this.showToast('Info', 'No changes to save.', 'info');
                return;
            }
            
            // Update matrix data on server
            const result = await updateMatrixData({
                matrixVersionId: this.matrixVersionId,
                updatedRecords: editedRecords
            });
            
            console.log('Update result:', result);
            
            // Clear draft values first
            this.draftValues = [];
            this.hasUnsavedChanges = false;
            this.editedRowsCount = 0;
            
            // Refresh data from server
            await this.loadMatrixData();
            
            this.showToast('Success', result || 'Matrix data updated successfully.', 'success');
            
        } catch (error) {
            console.error('Error saving matrix edits:', error);
            this.showToast('Error', 'Error saving matrix edits: ' + (error.body?.message || error.message), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Add new method to merge draft values properly
    mergeDraftValues(existingDraftValues, newDraftValues) {
        const mergedMap = new Map();
        
        // First, add all existing draft values to the map
        if (existingDraftValues && Array.isArray(existingDraftValues)) {
            existingDraftValues.forEach(draft => {
                if (draft && draft.rowNumber) {
                    const rowNumber = parseInt(draft.rowNumber);
                    mergedMap.set(rowNumber, { ...draft });
                }
            });
        }
        
        // Then, merge in the new draft values
        if (newDraftValues && Array.isArray(newDraftValues)) {
            newDraftValues.forEach(newDraft => {
                if (newDraft && newDraft.rowNumber) {
                    const rowNumber = parseInt(newDraft.rowNumber);
                    const existingDraft = mergedMap.get(rowNumber) || {};
                    
                    // Merge the new draft with existing draft for this row
                    const mergedDraft = { ...existingDraft, ...newDraft };
                    mergedMap.set(rowNumber, mergedDraft);
                }
            });
        }
        
        // Convert map back to array
        return Array.from(mergedMap.values());
    }

    // Update the applyDraftValuesToData method to handle the merged draft values better
    applyDraftValuesToData(data) {
        if (!this.draftValues || this.draftValues.length === 0) {
            return data;
        }
        
        // Create a map of draft values by rowNumber for quick lookup
        const draftMap = new Map();
        this.draftValues.forEach(draft => {
            if (draft.rowNumber) {
                const rowNumber = parseInt(draft.rowNumber);
                draftMap.set(rowNumber, draft);
            }
        });
        
        // Apply draft values to corresponding records
        return data.map(record => {
            const recordRowNumber = parseInt(record.rowNumber);
            const draftValues = draftMap.get(recordRowNumber);
            
            if (draftValues) {
                // Create a new record with draft values applied
                const updatedRecord = { ...record };
                
                // Apply each field from draft values
                Object.keys(draftValues).forEach(key => {
                    if (key !== 'rowNumber') { // Don't override rowNumber
                        updatedRecord[key] = draftValues[key];
                    }
                });
                
                // Ensure rowNumber remains an integer
                updatedRecord.rowNumber = recordRowNumber;
                return updatedRecord;
            }
            return record;
        });
    }

    // Update the handleCancelEdits method to properly clear all edits
    handleCancelEdits() {
        // Clear all draft values
        this.draftValues = [];
        this.hasUnsavedChanges = false;
        this.editedRowsCount = 0;
        
        // Force the datatable to refresh by clearing and re-setting the data
        const currentData = [...this.tableData];
        this.tableData = [];
        
        // Use setTimeout to ensure the datatable re-renders
        setTimeout(() => {
            if (this.showPreview) {
                this.applyPreviewPagination();
            } else {
                this.loadMatrixData();
            }
        }, 100);
        
        this.showToast('Info', 'All changes have been cancelled.', 'info');
    }

    // Update handleSaveMatrixVersion to use updated preview data
    async handleSaveUpdatedPreviewAsVersion() {
        try {
            this.isLoading = true;
            this.errorMessage = '';
            
            if (!this.csvPreviewData || !this.csvPreviewData.headers) {
                this.showToast('Error', 'No preview data available to save.', 'error');
                return;
            }
            
            // Use the updated preview data (including any edits)
            const dataToSave = this.allPreviewData;
            const headers = this.csvPreviewData.headers;
            
            const matrixId = this.calculationMatrixId || this.recordId;
            
            console.log('Saving matrix version with updated data');
            
            // Save using the new method that handles updated records
            this.matrixVersionId = await saveUpdatedPreviewAsVersion({
                fileName: this.uploadedFileName,
                updatedRecords: dataToSave,
                headers: headers,
                matrixName: this.matrixName,
                calculationMatrixId: matrixId,
                columnConfigs: this.columnConfigurations
            });
            
            this.fileName = this.uploadedFileName;
            this.hasUploadedFile = true;
            this.showMatrixNameInput = false;
            this.selectedVersionId = this.matrixVersionId;
            this.showPreview = false;
            this.isReadyToSave = false;
            this.showColumnConfig = false;
            
            // Clear editing state
            this.draftValues = [];
            this.hasUnsavedChanges = false;
            this.editedRowsCount = 0;
            
            // Clear temporary data
            this.csvPreviewData = null;
            this.uploadedFileContent = '';
            this.uploadedFileName = '';
            this.allPreviewData = [];
            
            // Load first page of data
            await this.loadMatrixData();
            
            this.showToast('Success', 'Matrix Version saved successfully with your edits!', 'success');
        } catch (error) {
            console.error('Save version error:', error);
            this.errorMessage = error.body?.message || error.message || 'Unknown error occurred while saving version.';
            this.showToast('Save Error', this.errorMessage, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleToggleMatrix() {
        try {
            this.isLoading = true;
            
            if (this.isMatrixEnabled) {
                // If currently enabled, disable it
                await toggleMatrixVersion({ 
                    matrixVersionId: this.selectedVersionId,
                    isEnabled: false
                });
                this.showToast('Success', 'Matrix version disabled successfully.', 'success');
            } else {
                // If currently disabled, enable it
                await enableOnlySelectedMatrixVersion({ 
                    matrixVersionId: this.selectedVersionId 
                });
                this.showToast('Success', 'Matrix version enabled successfully.', 'success');
            }
            
            // Refresh matrix info and data
            await this.refreshMatrixVersions();
            await this.loadSelectedVersion();
        } catch (error) {
            this.showToast('Error', error.body?.message || error.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Add computed properties for edit mode
    get showEditControls() {
        return this.hasData && this.tableData.length > 0;
    }

    get editButtonLabel() {
        return this.hasUnsavedChanges ? `Save Changes (${this.editedRowsCount})` : 'Save Changes';
    }

    get editButtonVariant() {
        return this.hasUnsavedChanges ? 'brand' : 'neutral';
    }

    get editButtonDisabled() {
        return !this.hasUnsavedChanges;
    }

    get editStatusText() {
        if (this.hasUnsavedChanges) {
            return `You have ${this.editedRowsCount} unsaved change${this.editedRowsCount !== 1 ? 's' : ''}`;
        }
        return 'Click on any cell to edit. Use Save/Cancel buttons to manage changes.';
    }

    // Add these computed properties for the conditional expressions
    get editedRowsText() {
        return this.editedRowsCount !== 1 ? 's' : '';
    }

    get editedRowsRowText() {
        return this.editedRowsCount !== 1 ? 's' : '';
    }

    get editedRowsCountText() {
        return this.editedRowsCount || 0;
    }

    // Update existing computed properties
    get unsavedChangesMessage() {
        const changesText = this.editedRowsCount !== 1 ? 's' : '';
        const rowsText = this.editedRowsCount !== 1 ? 's' : '';
        return `You have ${this.editedRowsCount} unsaved change${changesText} across ${this.editedRowsCount} row${rowsText}. Don't forget to save your edits!`;
    }

    // Add the missing handleSort method
    handleSort(event) {
        const { fieldName: sortedBy, sortDirection } = event.detail;
        console.log('Sorting by:', sortedBy, 'Direction:', sortDirection);
        
        this.sortedBy = sortedBy;
        this.sortedDirection = sortDirection;
        
        // Sort the current table data
        this.tableData = this.sortData([...this.tableData], sortedBy, sortDirection);
    }
    
    async handleRemoveMatrix(event) {
        const versionId = this.selectedVersionId;
        try {
            this.isLoading = true;
            await deleteMatrixVersion({ matrixVersionId: versionId });
            this.showToast('Success', 'Matrix version deleted successfully.', 'success');
            
            // Refresh the versions list
            await this.refreshMatrixVersions();

            // If the deleted version was selected, clear selection and data
            if (this.selectedVersionId === versionId) {
                this.selectedVersionId = '';
                this.matrixVersionId = '';
                this.hasUploadedFile = false;
                this.tableData = [];
                this.tableColumns = [];
                this.totalRecords = 0;
                this.currentPage = 1;
                this.totalPages = 0;
            }
        } catch (error) {
            this.showToast('Error', error.body?.message || error.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // Add this helper method to refresh versions
    async refreshMatrixVersions() {
        try {
            const data = await getMatrixVersions({ calculationMatrixId: this.effectiveMatrixId });
            this.matrixVersions = data.map(version => ({
                label: version.label,
                value: version.value
            }));
            this.showVersionDropdown = this.matrixVersions.length > 0;
        } catch (error) {
            this.matrixVersions = [];
            this.showVersionDropdown = false;
        }
    }

    handleColumnConfigChange(event) {
        this.columnConfigurations = event.detail.columnConfigs;
        console.log('Updated column configurations:', this.columnConfigurations);
    }

    // Add these methods for column configuration
    handleHeaderTypeChange(event) {
        const index = event.target.dataset.index;
        this.columnConfigurations[index].headerType = event.detail.value;
        console.log('Updated header type:', this.columnConfigurations[index].name, 'to', event.detail.value);
    }

    handleDataTypeChange(event) {
        const index = event.target.dataset.index;
        this.columnConfigurations[index].dataType = event.detail.value;
        console.log('Updated data type:', this.columnConfigurations[index].name, 'to', event.detail.value);
    }

    // Update this method to include showing column config
    handleConfigureColumns() {
        console.log('Opening column configuration...');
        this.showColumnConfig = true;
    }

    // Make sure this method exists and works
    handleCancelColumnConfig() {
        console.log('Canceling column configuration...');
        this.showColumnConfig = false;
    }

    // Make sure this method exists and works
    handleSaveColumnConfig() {
        console.log('Saving column configuration...');
        this.showColumnConfig = false;
        this.showToast('Success', 'Column configuration saved. These settings will be applied when you save the matrix version.', 'success');
    }
}