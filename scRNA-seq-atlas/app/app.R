library(shiny)
library(shinyjs)
library(waiter)
library(dplyr)
library(readr)
library(tools)
library(clustifyr)
library(rsconnect)
library(ExperimentHub)
library(Seurat)
library(shinydashboard)
library(tidyverse)
library(data.table)
library(R.utils)
library(DT)
# library(ComplexHeatmap)

options(shiny.maxRequestSize = 1500 * 1024^2)
options(repos = BiocManager::repositories())
options(shiny.reactlog = TRUE)
options(DT.options = list(
  dom = "tp", 
  paging = TRUE,
  pageLength = 6,
  scrollX = TRUE
  )
)

eh <- ExperimentHub()
refs <- query(eh, "clustifyrdatahub")
ref_dict <- refs$ah_id %>% setNames(refs$title)

js <- c(
  "table.on('click', 'td', function(){",
  "  var cell = table.cell(this);",
  "  var colindex = cell.index().column;",
  "  var colname = table.column(colindex).header().innerText;",
  "  Shiny.setInputValue('column_clicked', colname);",
  "});"
)

# Define UI for data upload app ----
ui <- dashboardPage(
  dashboardHeader(title = "Clustifyr RShiny App"),
  dashboardSidebar(
    sidebarMenu(
      id = "tabs",
      menuItem("Dashboard", tabName = "dashboard", icon = icon("dashboard")),
      menuItem("Load Matrix", tabName = "matrixLoad", icon = icon("th")),
      menuItem("Load Metadata", tabName = "metadataLoad", icon = icon("th")),
      menuItem("Choose cluster and ref column", tabName = "clusterRefCol", icon = icon("th"))
    )
    
  ),
  dashboardBody(
    tabItems(
      tabItem(
        tabName = "dashboard",
        # js stuff ----
        useShinyjs(),
        tags$head(tags$style(HTML('
            .skin-blue .sidebar .inactiveLink {
                color: black;
                opacity : 25%;
            }'
        ))),
        tags$head(tags$style(".inactiveLink {
                           pointer-events: none;
                           cursor: not-allowed;
                           }")),
        tags$head(tags$style(HTML('
            .skin-blue .sidebar .doneLink {
                color: green;
            }'
        ))),
        tags$head(tags$style(HTML('
            .skin-blue .sidebar .doneLink.active > a {
                color: green;
                border-left-color: green;
            }'
        ))),
        tags$head(tags$style(HTML('
            .skin-blue .sidebar .doneLink:hover {
                color: green;
                border-left-color: green;
            }'
        ))),
        
        # waiter stuff ----
        use_waiter(),

        # load example data ----
        actionButton("example",
          "load example data",
          icon = icon("space-shuttle")
        ),

        # Input: Checkbox if file has header ----
        checkboxInput("header", "Header", TRUE),


        # Horizontal line ----
        tags$hr(),

        # Input: Select separator ----
        radioButtons("sepMat", "Separator - Matrix",
          choices = c(
            Comma = ",",
            Semicolon = ";",
            Tab = "\t"
          ),
          selected = ","
        ),
        
        radioButtons("sepMeta", "Separator - Metadata",
                     choices = c(
                       Comma = ",",
                       Semicolon = ";",
                       Tab = "\t"
                     ),
                     selected = ","
        ),
        
        # Input: Select number of rows to display ----
        radioButtons("dispMat", "Display - Matrix",
                     choices = c(
                       Head = "head",
                       All = "all"
                     ),
                     selected = "head"
        ),
        radioButtons("dispMeta", "Display - Metadata",
          choices = c(
            Head = "head",
            All = "all"
          ),
          selected = "head"
        )
      ),
      tabItem(
        tabName = "matrixLoad",
        h2("Load UMI Counts Matrix"),
        # Input: Select a file ----
        fileInput("file1", "Choose Matrix File",
          multiple = TRUE,
          accept = c(
            "text/csv",
            "text/comma-separated-values,text/plain",
            ".csv",
            ".xlsx",
            ".tsv",
            ".rds",
            ".rda"
          )
        ),
        actionButton("matrixPopup", "Display UMI Matrix in popup"),
        DTOutput("contents1"), # UMI Count Matrix
        tags$hr()
      ),
      tabItem(
        tabName = "metadataLoad",
        h2("Load Metadata table"),
        fileInput("file2", "Choose Metadata File",
          multiple = FALSE,
          accept = c(
            "text/csv",
            "text/comma-separated-values,text/plain",
            ".csv",
            ".xlsx",
            ".tsv",
            ".rds",
            ".rda"
          )
        ),

        actionButton("metadataPopup", "Display Metadata table in popup"),
        fluidRow(column(12, DTOutput('contents2'))),
        #DT::dataTableOutput("contents2"), # Metadata table
        tags$hr(),
        textOutput("colclicked"),
        
        h2("Choose cluster and reference column (cell types)"),
        selectInput("metadataCellType", "Cell Type Metadata Column:",
                    choice = list("")
        ),
        
        helpText("Choose cell type metadata column for average_clusters function"),
        hr(),
        selectInput("dataHubReference", "ClustifyrDataHub Reference:",
                    choices = list(
                      "ref_MCA", "ref_tabula_muris_drop", "ref_tabula_muris_facs",
                      "ref_mouse.rnaseq", "ref_moca_main", "ref_immgen", "ref_hema_microarray",
                      "ref_cortex_dev", "ref_pan_indrop", "ref_pan_smartseq2",
                      "ref_mouse_atlas"
                    )
        ),
        helpText("Choose reference cell atlas for clustify function"),
        hr(),
        helpText("Choose cell reference for clustify function"),
      ),
      tabItem(
        tabName = "clusterRefCol",
        box(id = "box_clustifym",
            collapsible = TRUE,
            collapsed = TRUE,
            solidHeader = TRUE,
            status = "info",
            title = "clustifyr messages",
            htmlOutput("clustifym")),
        downloadButton("downloadReference", "Download reference matrix"),
        downloadButton("downloadClustify", "Download clustify matrix"),
        actionButton("uploadClustify", "Upload reference matrix"),

        DT::dataTableOutput("reference"), # Reference Matrix
        tags$hr(),
        DT::dataTableOutput("clustify"), # Clustify Matrix
        tags$hr(),
        plotOutput("hmap", height = "600px")
      )
    )
  )
)

# Define server logic to read selected file ----
server <- function(input, output, session) {

  # reactive file location to make interactivity easier
  rv <- reactiveValues()
  rv$matrixloc <- NULL
  rv$metaloc <- NULL
  rv$step <- 0
  rv$clustifym <- "clustifyr not yet run"


  # waiter checkpoints
  w1 <- Waiter$new(
    id = "contents1",
    html = tagList(
      spin_flower(),
      h4("Matrix loading..."),
      h4("")
    )
  )

  w2 <- Waiter$new(
    id = "contents2",
    html = tagList(
      spin_flower(),
      h4("Metadata loading..."),
      h4("")
    )
  )

  w3 <- Waiter$new(
    id = "reference",
    html = tagList(
      spin_flower(),
      h4("Reference building..."),
      h4("")
    )
  )

  w4 <- Waiter$new(
    id = "clustify",
    html = tagList(
      spin_flower(),
      h4("Clustifyr running..."),
      h4("")
    )
  )

  w5 <- Waiter$new(
    id = "hmap",
    html = tagList(
      spin_flower(),
      h4("Heatmap drawing..."),
      h4("")
    )
  )

  data1 <- reactive({

    # input$file1 will be NULL initially. After the user selects
    # and uploads a file, head of that data file by default,
    # or all rows if selected, will be shown.

    if (!is.null(input$file1)) {
      rv$matrixloc <- input$file1
    }

    file <- rv$matrixloc

    if (!is.null(file)) {
      w1$show()
      print(file)
    }

    fileTypeFile1 <- tools::file_ext(file$datapath)
    req(file)
    
    df1 <- fread(file$datapath) %>% # , header = input$header, sep = input$sepMat) %>% 
      as.data.frame()
    
    if (!has_rownames(df1)) {
        rownames(df1) <- df1[, 1]
        df1[, 1] <- NULL
    }

    w1$hide()
    df1
  })

  data2 <- reactive({
    if (!is.null(input$file2)) {
      rv$metaloc <- input$file2
    }
    file <- rv$metaloc

    if (!is.null(file)) {
      w2$show()
      print(file)
    }

    fileTypeFile2 <- tools::file_ext(file$datapath)
    req(file)
    
    df2 <- fread(file$datapath) %>% #, header = input$header, sep = input$sepMeta) %>% 
      as.data.frame()
    
    if (!has_rownames(df2)) {
      rownames(df2) <- df2[, 1]
      df2[, 1] <- NULL
    }

    updateSelectInput(session, "metadataCellType",
      choices = c("", colnames(df2)),
      selected = ""
    )
    
    w2$hide()
    df2
  })

  output$contents1 <- DT::renderDataTable({
    df1 <- data1()
    # file 1
    if (input$dispMat == "head") {
      return(head(df1, cols = 5))
    }
    else {
      return(df1)
    }
  })

  output$contents2 <- DT::renderDataTable({
    df2 <- data2()
    # file 2
    if (input$dispMeta == "head") {
      return(head(df2))
    }
    else {
      return(df2)
    }
    
  }, 
  callback = DT::JS(js), 
  selection = list(target = 'column', mode = "single"))
  
  output$colclicked <- renderPrint({
    input[["column_clicked"]]
  })
  
  observeEvent(input[["column_clicked"]], {
    updateSelectInput(session, "metadataCellType", 
      selected = input[["column_clicked"]]                   
    )
  })
  
  

  observeEvent(input$matrixPopup, {
    showModal(modalDialog(
      tags$caption("Matrix table"),
      DT::renderDataTable({
        matrixRender <- head(data1())
        DT::datatable(matrixRender)
      }),
      easyClose = TRUE
    ))
  })

  observeEvent(input$metadataPopup, {
    showModal(modalDialog(
      tags$caption("Metadata table"),
      DT::renderDataTable({
        matrixRender <- head(data2())
        DT::datatable(matrixRender)
      }),
      easyClose = TRUE
    ))
  })
  
  dataRef <- reactive({
    if (input$metadataCellType == "") {
      return(NULL)
    }
    w3$show()
    reference_matrix <- average_clusters(mat = data1(), metadata = data2()[[input$metadataCellType]], if_log = FALSE)
    w3$hide()
    reference_matrix
  })

  dataClustify <- reactive({
    if (input$metadataCellType == "") {
      return(NULL)
    }
    w4$show()
    benchmarkRef <- refs[[ref_dict[input$dataHubReference]]]

    UMIMatrix <- data1()
    matrixSeuratObject <- CreateSeuratObject(counts = UMIMatrix, project = "Seurat object matrix", min.cells = 0, min.features = 0)
    matrixSeuratObject <- FindVariableFeatures(matrixSeuratObject, selection.method = "vst", nfeatures = 2000)

    metadataCol <- data2()[[input$metadataCellType]]
    # use for classification of cell types
    messages <<- capture.output(
      res <- clustify(
        input = matrixSeuratObject@assays$RNA@data,
        metadata = metadataCol,
        ref_mat = benchmarkRef,
        query_genes = VariableFeatures(matrixSeuratObject)
        ),
      type = "message"
    )
    rv$clustifym <<- messages

    w4$hide()
    res
  })

  output$reference <- DT::renderDataTable({
    reference_matrix <- dataRef()
    if (is.null(reference_matrix)) {
      return(NULL)
    }
    rownames_to_column(as.data.frame(reference_matrix), input$metadataCellType)
  })

  output$clustify <- DT::renderDataTable({
    res <- dataClustify()
    if (is.null(res)) {
      return(NULL)
    }
    rownames_to_column(as.data.frame(res), input$metadataCellType)
  })

  # Make plots such as heat maps to compare benchmarking with clustify with actual cell types

  output$hmap <- renderPlot({
    if (input$metadataCellType == "") {
      return(NULL)
    }
    
    # could expose as an option
    cutoff_to_display <- 0.5
    tmp_mat <<- dataClustify()

    if (!is.null(tmp_mat)) {
      w5$show()
    }
    tmp_mat <- tmp_mat[, colSums(tmp_mat > 0.5) > 1]
    s <- dim(tmp_mat)
    # figuring out how best to plot width and height based on input matrix size needs work
    # this is pretty ugly currently
    w <- unit(8 + (s[2] / 30), "inch")
    h <- unit(8 + (s[1] / 30), "inch")
    fs <- min(12, c(12:6)[findInterval(s[2], seq(6, 200, length.out = 7))])

    hmap <- plot_cor_heatmap(tmp_mat, width = w)

    ComplexHeatmap::draw(hmap,
      height = h,
      heatmap_column_names_gp = gpar(fontsize = fs)
    )
  })

  referenceDownload <- reactive({
    referenceMatrix <- dataRef()
  })

  clustifyDownload <- reactive({
    clustifyMatrix <- dataClustify()
  })

  output$downloadReference <- downloadHandler(
    filename = function() {
      paste("reference-", Sys.Date(), ".csv", sep = "")
    },
    content = function(file) {
      write.csv(referenceDownload(), file)
      # mat %>% as_tibble(rownames = "rowname") %>% write_csv("mat.csv")
    }
  )
  output$downloadClustify <- downloadHandler(
    filename = function() {
      cat("clustify-", Sys.Date(), ".csv", sep = "")
    },
    content = function(file) {
      write.csv(clustifyDownload(), file)
      # mat %>% as_tibble(rownames = "rowname") %>% write_csv("mat.csv")
    }
  )

  # load example data
  observeEvent(
    input$example,
    {
      message("loading prepackaged data")
      rv$matrixloc <- list(datapath = "../data/example-input/matrix.csv")
      rv$metaloc <- list(datapath = "../data/example-input/meta-data.csv")
      updateTabItems(session, "tabs", "clusterRefCol")
    }
  )
  
  output$clustifym <- renderUI(
    HTML(paste0(c(rv$clustifym, ""), collapse = "<br/><br/>"))
  )
  
  # disable menu at load
  addCssClass(selector = "a[data-value='clusterRefCol']", class = "inactiveLink")
  addCssClass(selector = "ul li:eq(3)", class = "inactiveLink")
  
  # check if data is loaded
  observeEvent(!is.null(data1()) + !is.null(data2()) == 2, {
    removeCssClass(selector = "a[data-value='clusterRefCol']", class = "inactiveLink")
    removeClass(selector = "ul li:eq(3)", class = "inactiveLink")
  })
  
  observeEvent(!is.null(data1()), {
    addCssClass(selector = "a[data-value='matrixLoad']", class = "doneLink")
    addClass(selector = "ul li:eq(1)", class = "doneLink")
  })
  
  observeEvent(!is.null(data2()), {
    addCssClass(selector = "a[data-value='metadataLoad']", class = "doneLink")
    addClass(selector = "ul li:eq(2)", class = "doneLink")
  })

}

# Create Shiny app ----
shinyApp(ui, server)
