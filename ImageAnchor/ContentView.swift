//
//  ContentView.swift
//  ImageAnchor
//
//  Created by Nien Lam on 9/21/21.
//  Copyright © 2021 Line Break, LLC. All rights reserved.
//

import SwiftUI
import ARKit
import RealityKit
import Combine
import CoreMotion
import AVFoundation
import CoreAudio
import Firebase
import FirebaseDatabase

// Data from MET Website:
struct METQueryData: Codable{
    let total: Int
    let objectIDs: [Int]
}

struct METObjectInfoData: Codable {
    let objectID: Int
    let primaryImage: String
    let primaryImageSmall: String
    let title: String
    let culture: String
    let period: String
    let dynasty: String
    let reign: String
    let artistDisplayName: String
    let artistDisplayBio: String
    let objectDate: String
    let dimensions: String
    let city: String
    let country: String
    let objectURL: String
}

// Data to store in the Firebase.
struct MyData: Codable {
    let timeStamp: String
    let dailyArt: METObjectInfoData
    let dailyQuery: String
}

enum AppState{
    case menu
    case addEntry
    case viewTodaysEntry
    case viewDiary
}

extension Image {
    func data(url:URL) -> Self {
        if let data = try? Data(contentsOf: url) {
        return Image(uiImage: UIImage(data: data)!)
        .resizable()
    }
        return self
            .resizable()
    }

}


// MARK: - View model for handling communication between the UI and ARView.
class ViewModel: ObservableObject {
    @Published var titleText = "My Collection"
    @Published var counter: Int = 0
    
    // DB Stuff
    @Published var hasStartedDb = false
    @Published var rootRef: DatabaseReference!
  
    @Published var appState: AppState = AppState.menu
    
    // Daily emotion
    @Published var canEnterDailyEntry = false
    @Published var dailyPhrase: String = ""
    @Published var hasSubmittedInput = false
    @Published var dailyArt: METObjectInfoData?

    let uiSignal = PassthroughSubject<UISignal, Never>()
    
    enum UISignal {
        case returnToMenu
    }
    
    func startUpFirebase(){
        // Firebase setup.
        FirebaseApp.configure()

        // TODO: Added url.
        // NOTE: Url is visible in Firebase console for project.
        let url = "https://augmented-spaces-hw-7-default-rtdb.firebaseio.com/"
        rootRef = Database.database(url: url).reference()
        self.hasStartedDb = true;
    }
    
    func setCanEnterInput(){
        var totalEntriesInDb = 0;

        // Get current day.
        let today = Date();
        let calendar = Calendar.current
        let calendarComp = calendar.dateComponents([.month, .year,.day], from: today)
        
        var tempCanEnterDaily = true
        
       rootRef.getData(completion: {
           error, snapshot in
           guard error == nil else {
               print(error!.localizedDescription)
               return;
           }
           print("No error");
           print(snapshot.childrenCount)
           if(snapshot.childrenCount==0){
               self.canEnterDailyEntry = true
           }
         });
        
        // Observe whenever a record is added.
        rootRef.observe(.childAdded, with: { snapshot in
             totalEntriesInDb+=1;
            
            // Convert data into JSON.
            let dict = snapshot.value as? [String : AnyObject] ?? [:]
            let jsonData = try! JSONSerialization.data(withJSONObject: dict, options: [])
            
            // Map JSON to your data structure.
            let decoder = JSONDecoder()
            if let myData = try? decoder.decode(MyData.self, from: jsonData) {
                // Print data.
                //print("📝:", myData)
                
                let timeStampSplit = myData.timeStamp.split(separator: "/")
                let monthInt = Int(timeStampSplit[0])
                let dayInt = Int(timeStampSplit[1])
                let yearInt = Int(timeStampSplit[2].split(separator: ",")[0])
                
                
                print(monthInt == calendarComp.month)
                print(dayInt == calendarComp.day)
                print(yearInt == calendarComp.year)

                let hasSubmittedAlreadyToday = monthInt == calendarComp.month && dayInt == calendarComp.day && yearInt == calendarComp.year
                if(hasSubmittedAlreadyToday){
                    print("detected entry submitted for the day");
                    tempCanEnterDaily = false
                }
            }//end of try
            else {
                print("❌ Error mapping data.")
                return
            }
            
            print("end of loop");
            print(self.canEnterDailyEntry);
            
            //TODO: uncomment out for testing purposes
            self.canEnterDailyEntry = tempCanEnterDaily;
            //self.canEnterDailyEntry = true;

        })//end of observation
    }
    
    func writeToDb(todaysArt: METObjectInfoData, dailyQuery: String ){
        // Get current time.
        let timeStamp = Date().formatted(date: .numeric, time: .standard)
        
        let ref = Database.database().reference(withPath: UUID().uuidString)

        // Create a new data object.
        let myData = MyData(timeStamp: timeStamp, dailyArt:todaysArt, dailyQuery: dailyQuery )

        // Encode object to JSON.
        let jsonEncoder = JSONEncoder()
        let jsonData    = try! jsonEncoder.encode(myData)
        let json        = try! JSONSerialization.jsonObject(with: jsonData, options: [])
       
        // Write to database.
        ref.setValue(json)
    
        // Can see continue button
        hasSubmittedInput = true
    }
    
    func getMetObjIdsByQueryParameter(query: String = "Auguste%20Renoir" ){
        // TODO: Replace query later
         if( query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty){
            print("Empty string, returning");
            return;
        }
        let param = query.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)
        print(param!)
        let url = URL(string: "https://collectionapi.metmuseum.org/public/collection/v1/search?hasImages=true&q=\(param!)")
        print(url)
        let session = URLSession.shared
        let task = session.dataTask(with: url!) { data, response, error in
            if error != nil || data == nil {
                print("Client error!")
                return
            }
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                print("Server error!")
                return
            }
            guard let mime = response.mimeType, mime == "application/json" else {
                print("Wrong MIME type!")
                return
            }
            do {
               // Map JSON to your data structure.
                let decoder = JSONDecoder()
                                
                guard let myData = try? decoder.decode(METQueryData.self, from: data!)  else {
                    print("❌ Error mapping data.")
                    return
                }
                let randomEle = myData.objectIDs.randomElement();
                self.getDrawingInfoByObjId(objId: randomEle!, dailyQuery: query);
            } catch {
                print("JSON error: \(error.localizedDescription)")
            }
        }

        task.resume()
    }//end of func 1
    
    func getDrawingInfoByObjId(objId: Int, dailyQuery: String){
        let id = String(objId)
         let url = URL(string: "https://collectionapi.metmuseum.org/public/collection/v1/objects/\(id)")!
        
        let session = URLSession.shared
 
        let task = session.dataTask(with: url) { data, response, error in

            if error != nil || data == nil {
                print("Client error!")
                return
            }

            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                print("Server error!")
                return
            }

            guard let mime = response.mimeType, mime == "application/json" else {
                print("Wrong MIME type!")
                return
            }

            do {
                
                let jsonData = try JSONSerialization.jsonObject(with: data!, options: [])
                
                print("retrieved data");
                do{
                    let decoder = JSONDecoder()
                    let myData = try decoder.decode(METObjectInfoData.self, from: data!)
                    print(myData.title)
                    
                    self.dailyArt = myData
                    
                    self.writeToDb(todaysArt: myData, dailyQuery: dailyQuery)
            
                }
                catch{
                    print(error)
                }
                
            } catch {
                print("JSON error: \(error.localizedDescription)")
            }
        }

        task.resume()
        
    }//end of func 2
    
}

// MARK: - UI Layer.
struct ContentView : View {
    @StateObject var viewModel: ViewModel
    
    var body: some View {
         
        ZStack {
            
            if(viewModel.appState == AppState.menu){
                Color.white
                VStack(alignment: .center){
                    Spacer();
                    Text("Art A Day")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundColor(.black)
                        .font(.system(size: 50))
                        .padding()
                    
                    Text("Enter your emotion for the day and see what art best represents your mood")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundColor(.black)
                        .font(.system(.headline))
                        .padding()
                    
                    Spacer()

                    
                    Button {
                        print("Go to See Diary page");
                        viewModel.appState = AppState.viewDiary
                    } label: {
                        HStack{
                            Text("See Entries")
                                .foregroundColor(.red)
                                .font(.system(.title2))
                                     
                            Image(systemName: "book.closed.fill")
                                .foregroundColor(.red)
                                .font(.system(.title2))

                        }
                    }
                    .onAppear {
                        print("on start loading");
                        if(!viewModel.hasStartedDb){
                            viewModel.startUpFirebase()
                        }
                        viewModel.setCanEnterInput()
                    }

                    if(viewModel.canEnterDailyEntry){
                        Spacer()
                        Button {
                            // Go to input screen
                            print("Going to input screen");
                            viewModel.appState = AppState.addEntry
                            //viewModel.getMetObjIdsByQueryParameter();
                        } label: {
                            HStack{
                                Text("Enter Daily Emotion")
                                    .foregroundColor(.red)
                                    .font(.system(.title2))

                                         
                                Image(systemName: "note.text.badge.plus")
                                    .foregroundColor(.red)
                                    .font(.system(.title2))

                            }
                        }// end button
                    }
                    
                    Spacer();
                }//end of VStack
            }// end of menu
            
            else if(viewModel.appState == AppState.addEntry){
                Color.white
                VStack(alignment: .center){

                    Text("In a phrase, describe today's emotions or thoughts")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .foregroundColor(.black)
                        .font(.system(.largeTitle))
                    
                    Spacer()

                    
                    // Text field.
                    TextField("Enter Thoughts", text: $viewModel.dailyPhrase)
                        .lineSpacing(20)
                        .padding()
                        .font(.system(size: 18))
                        .frame(width: 300, height: 100)
                        .foregroundColor(.black)
                        .background(
                            Rectangle()
                                .stroke(lineWidth: 1.5)
                                .fill(.black)
                                .background(Color.white)
                        )
                    
                    
                    if(viewModel.hasSubmittedInput == false){
                        Button {
                            // Submit entry
                            viewModel.getMetObjIdsByQueryParameter(query: $viewModel.dailyPhrase.wrappedValue)
                            
                        } label: {
                            Text("Submit")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .font(.system(.largeTitle))
                                .foregroundColor(.red)
                        }
                    }

                    else if(viewModel.hasSubmittedInput){
                        Button {
                            // See entries
                            print("Going to view todays entry");
                            viewModel.appState = AppState.viewTodaysEntry
                            
                        } label: {
                            Text("See Today's Art")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .font(.system(.largeTitle))
                                .foregroundColor(.red)
                        }
                    }
                }
                
                
                
            }
            
            else if(viewModel.appState == AppState.viewTodaysEntry){
                
                VStack(alignment: .center){
                    
                    HStack{

                        Button {
                            viewModel.uiSignal.send(.returnToMenu)
                        } label: {
                            Label("Main menu", systemImage: "house")
                                .font(.system(.title2).weight(.medium))
                                .foregroundColor(.white)
                                .labelStyle(IconOnlyLabelStyle())
                                .frame(width: 30, height: 30)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding()
                    }//end of HStack
                    
                    Text(viewModel.dailyArt!.title)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .font(.system(.title))
                        .foregroundColor(.black)
                        .lineLimit(5)
 
                    Text(viewModel.dailyArt!.objectDate)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .font(.system(.headline))
                        .foregroundColor(.black)
                        .lineLimit(5)
                        .padding()
                    Image(systemName: "img")
                        .data(url: URL(string: viewModel.dailyArt!.primaryImageSmall)!)
                       .resizable()
                       .aspectRatio(contentMode: .fill)
                       .frame(width: 300, height: 300, alignment: .center)
                       .clipShape(Rectangle())
                    
                    Text(viewModel.dailyArt!.artistDisplayName)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .font(.system(.title3))
                        .foregroundColor(.black)
                        .lineLimit(5)
                        .padding()
                    
                    Text(viewModel.dailyArt!.artistDisplayBio)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .font(.system(.headline))
                        .foregroundColor(.black)
                        .lineLimit(5)
 
                    Button {
                        viewModel.appState = AppState.viewDiary
                    } label: {
                        HStack{
                            Text("See Journal Wall")
                                .foregroundColor(.red)
                                .font(.system(.headline))
                                     
                            Image(systemName: "book")
                                .foregroundColor(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
                }
                
            }
            
            else if(viewModel.appState == AppState.viewDiary){
                
                // AR View.
                ARViewContainer(viewModel: viewModel)
            
                // Reset button.
                Button {
                    viewModel.uiSignal.send(.returnToMenu)
                } label: {
                    Label("Main menu", systemImage: "house")
                        .font(.system(.title2).weight(.medium))
                        .foregroundColor(.white)
                        .labelStyle(IconOnlyLabelStyle())
                        .frame(width: 30, height: 30)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()

                // UI on the top row.
                HStack() {
                    Text("\(viewModel.titleText)")
                        .font(.custom("Inconsolata Black", size: 22))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)

            }
            
        }
        .edgesIgnoringSafeArea(.all)
        .statusBar(hidden: true)
                    
    }
    
    // Helper methods for rendering icon.
    func buttonIcon(_ systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .resizable()
            .padding(10)
            .frame(width: 44, height: 44)
            .foregroundColor(.white)
            .background(color)
            .cornerRadius(5)
    }
}


// MARK: - AR View.
struct ARViewContainer: UIViewRepresentable {
    let viewModel: ViewModel
    
    func makeUIView(context: Context) -> ARView {
        SimpleARView(frame: .zero, viewModel: viewModel)
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
}


class SimpleARView: ARView, ARSessionDelegate {
    var viewModel: ViewModel
    var arView: ARView { return self }
    var subscriptions = Set<AnyCancellable>()
    
    // Dictionary for tracking image anchors.
    var imageAnchorToEntity: [ARImageAnchor: AnchorEntity] = [:]
    
    // Variable for tracking ambient light intensity.
        var ambientIntensity: Double = 0
    

    // Materials array for animation.
    
    var materialsArray = [RealityKit.Material]()

    // Index for animation.
    var materialIdx = 0

    
    // Using plane entity for animation.
    var planeEntity: ModelEntity?
    
    // Example box entity.
    var boxEntity: ModelEntity?
    
    var allArt: [Art] = []

    init(frame: CGRect, viewModel: ViewModel) {
        self.viewModel = viewModel
        super.init(frame: frame)
    }
    
    required init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    required init(frame frameRect: CGRect) {
        fatalError("init(frame:) has not been implemented")
    }
    
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        
        UIApplication.shared.isIdleTimerDisabled = true
        
        setupScene()
    }
    
    func setupScene() {
        // Setup world tracking and plane detection.
        let configuration = ARImageTrackingConfiguration()
        arView.renderOptions = [.disableDepthOfField, .disableMotionBlur]

        // TODO: Update target image and physical width in meters. //////////////////////////////////////
        //let targetImage    = "itp-logo.jpg"
        let targetImage    = "IMG_9692.png"

        let physicalWidth  = 0.2524
        
        if let refImage = UIImage(named: targetImage)?.cgImage {
            let arReferenceImage = ARReferenceImage(refImage, orientation: .up, physicalWidth: physicalWidth)
            var set = Set<ARReferenceImage>()
            set.insert(arReferenceImage)
            configuration.trackingImages = set
        } else {
            print("❗️ Error loading target image")
        }
        
        arView.session.run(configuration)
//
//        // Called every frame.
//        scene.subscribe(to: SceneEvents.Update.self) { event in
//            // Call renderLoop method on every frame.
//            self.renderLoop()
//        }.store(in: &subscriptions)
        
        // Process UI signals.
        viewModel.uiSignal.sink { [weak self] in
            self?.processUISignal($0)
        }.store(in: &subscriptions)

        // Set session delegate.
        arView.session.delegate = self
    }
    
    // Process UI signals.
    func processUISignal(_ signal: ViewModel.UISignal) {
        switch signal {
        case .returnToMenu:
            viewModel.appState = AppState.menu
            break;
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        anchors.compactMap { $0 as? ARImageAnchor }.forEach {
            // Create anchor from image.
            let anchorEntity = AnchorEntity(anchor: $0)
            
            // Track image anchors added to scene.
            imageAnchorToEntity[$0] = anchorEntity
            
            // Add anchor to scene.
            arView.scene.addAnchor(anchorEntity)
            
            // Call setup method for entities.
            // IMPORTANT: Play USDZ animations after entity is added to the scene.
            setupEntities(anchorEntity: anchorEntity)
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if let intensity = frame.lightEstimate?.ambientIntensity {
            ambientIntensity = intensity
        }
    }

    
    

    // TODO: Setup entities. //////////////////////////////////////
    // IMPORTANT: Attach to anchor entity. Called when image target is found.

    func setupEntities(anchorEntity: AnchorEntity) {
        
        // Add directional light.
        let directionalLight = DirectionalLight()
        directionalLight.light.intensity = 750
        directionalLight.look(at: [0,0,0], from: [1, 1.1, 1.3], relativeTo: anchorEntity)
        directionalLight.shadow = DirectionalLightComponent.Shadow(maximumDistance: 0.5, depthBias: 2)
        anchorEntity.addChild(directionalLight)
        
        let artSize: Float = 0.070;
        var indx: Float = 0
        
        // Create Art data objs
        viewModel.rootRef?.observe(.childAdded, with: { snapshot in
            
            // Convert data into JSON.
            let dict = snapshot.value as? [String : AnyObject] ?? [:]
            let jsonData = try! JSONSerialization.data(withJSONObject: dict, options: [])
            
            // Map JSON to your data structure.
            let decoder = JSONDecoder()
            guard let myData = try? decoder.decode(MyData.self, from: jsonData)  else {
                print("❌ Error in ARView mapping data.")
                return
            }
            //print("In observation of childrenAdded: ");
            //print(myData);
            let entity = Art(query: myData.dailyQuery, time: myData.timeStamp, imgUrl: myData.dailyArt.primaryImageSmall, size: artSize)
            entity.name = myData.timeStamp
            
            print(entity.data)
            
             if(entity.data != nil){
                print("Adding Art");
                 self.displayArt(anchorEntity: anchorEntity, art: entity, ind: indx, artSize: artSize);
                 indx += 1
            }//end special if
            
        })//end getting data
               
    }
    
    func displayArt(anchorEntity: AnchorEntity, art: Art, ind: Float , artSize: Float){
        art.position.x =  (artSize * Float(Int(ind) % 3)) - 0.05
        art.position.z = -artSize * Float(Int(ind) / 3) + 0.05
        anchorEntity.addChild(art);
    }
    
}



class Art: Entity{
    
    var query: String
    var time: String
    var timeStampEntity : Entity?
    var data: Data?
    
    required init(query: String, time: String, imgUrl: String, size: Float){

        self.query = query
        self.time = time
        
        let timeStampSplit = time.split(separator: "/")
        let monthInt = Int(timeStampSplit[0])!
        let dayInt = Int(timeStampSplit[1])!
        let yearInt = Int(timeStampSplit[2].split(separator: ",")[0])!
        self.time = "\(String(describing: monthInt))/\(dayInt)/\(yearInt)"
        
        super.init()
        
        let remoteURL = URL(string: imgUrl)!
        // Create a temporary file URL to store the image at the remote URL.
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Download contents of imageURL as Data.  Use a URLSession if you want to do this asynchronously.
        let data = try! Data(contentsOf: remoteURL)
        
        // Write the image Data to the file URL.
        try! data.write(to: fileURL)
        do {
            self.data = data
            // Create a TextureResource by loading the contents of the file URL.
            let texture = try TextureResource.load(contentsOf: fileURL)
            var material = SimpleMaterial()
            material.baseColor = MaterialColorParameter.texture(texture)
            timeStampEntity = self.createTextEntity(text: self.time)
            //timeStamp.position.x
                    
            let pic = ModelEntity(mesh: .generatePlane(width: size, depth: size), materials: [material])
            timeStampEntity?.orientation *= simd_quatf(angle: -.pi/2, axis: [1, 0, 0])
            timeStampEntity?.position.z += 0.0375
            timeStampEntity?.position.x -= 0.02
            pic.position.y = -0.075
            timeStampEntity?.position.y = -0.065

            self.addChild(timeStampEntity!)
            self.addChild(pic);
            
        } catch {
            print(error.localizedDescription)
        }
        
    }
    
    required init() {
        fatalError("init() has not been implemented")
    }
    
    func createTextEntity(text: String) -> Entity {
        //let meshFont = MeshResource.Font(name: "Inconsolata Black", size: 0.04)!
        let systemFont: UIFont = .systemFont(ofSize: 0.007)
        
        let textMesh = MeshResource.generateText(text,
                                                 extrusionDepth: 0.02,
                                                 font: systemFont)

        let black  = SimpleMaterial(color: .white, isMetallic: false)
        return ModelEntity(mesh: textMesh, materials: [black])
    }
    
    
}
