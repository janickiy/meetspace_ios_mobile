// Test-only synthetic Pion client for the unchanged MeetSpace SFU.
// It validates signaling and RTP forwarding, not native camera/audio quality or device interoperability.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

var stage = "startup"
var client = &http.Client{Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect") }}

func request(base, token, method, path string, body any, result any) error {
	encoded, err := json.Marshal(body)
	if err != nil {
		return errors.New("encode")
	}
	req, err := http.NewRequest(method, base+"/api/v1"+path, bytes.NewReader(encoded))
	if err != nil {
		return errors.New("request")
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(req)
	if err != nil {
		return errors.New("http")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("http_%d", response.StatusCode)
	}
	if result == nil {
		_, _ = io.Copy(io.Discard, response.Body)
		return nil
	}
	if json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(result) != nil {
		return errors.New("decode")
	}
	return nil
}

func account(base string) (string, error) {
	email, password := uuid.NewString()+"@example.test", uuid.NewString()
	if err := request(base, "", "POST", "/auth/register", map[string]string{"email": email, "password": password, "displayName": "Synthetic SFU probe"}, nil); err != nil {
		return "", err
	}
	var login struct {
		AccessToken string `json:"accessToken"`
	}
	err := request(base, "", "POST", "/auth/login", map[string]string{"email": email, "password": password}, &login)
	if err != nil || login.AccessToken == "" {
		return "", errors.New("login")
	}
	return login.AccessToken, nil
}

type envelope struct {
	Version      int             `json:"version"`
	ID           string          `json:"id"`
	Type         string          `json:"type"`
	ConferenceID string          `json:"conferenceId"`
	Timestamp    time.Time       `json:"timestamp"`
	Data         json.RawMessage `json:"data"`
	ReplyTo      string          `json:"replyTo,omitempty"`
}
type peer struct {
	room         string
	socket       *websocket.Conn
	write        sync.Mutex
	pc           *webrtc.PeerConnection
	peerID       string
	source       []*webrtc.RTPTransceiver
	negotiation  string
	pending      bool
	dirty        bool
	remoteICE    []webrtc.ICECandidateInit
	failures     chan error
	done         chan struct{}
	readDone     chan struct{}
	once         sync.Once
	workers      sync.WaitGroup
	audio        atomic.Int64
	video        atomic.Int64
	negotiations atomic.Int64
}

func (p *peer) send(kind string, data any) error {
	raw, err := json.Marshal(data)
	if err != nil {
		return err
	}
	p.write.Lock()
	defer p.write.Unlock()
	_ = p.socket.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return p.socket.WriteJSON(envelope{Version: 1, ID: uuid.NewString(), Type: kind, ConferenceID: p.room, Timestamp: time.Now().UTC(), Data: raw})
}
func (p *peer) fail(err error) {
	select {
	case p.failures <- err:
	default:
	}
}
func connect(base, token, room string) (*peer, error) {
	var ticket struct {
		Ticket string `json:"ticket"`
	}
	if err := request(base, token, "POST", "/conferences/"+room+"/ws-ticket", map[string]string{"clientId": uuid.NewString()}, &ticket); err != nil {
		return nil, err
	}
	dialer := websocket.Dialer{Subprotocols: []string{"go-recorder.v1"}, HandshakeTimeout: 5 * time.Second}
	socket, _, err := dialer.Dial(strings.Replace(base, "http://", "ws://", 1)+"/api/v1/conferences/"+room+"/ws?ticket="+ticket.Ticket, nil)
	if err != nil {
		return nil, errors.New("websocket")
	}
	p := &peer{room: room, socket: socket, failures: make(chan error, 4), done: make(chan struct{}), readDone: make(chan struct{})}
	p.workers.Add(1)
	go func() {
		defer p.workers.Done()
		defer close(p.readDone)
		if err := p.loop(); err != nil {
			select {
			case <-p.done:
			default:
				p.fail(err)
			}
		}
	}()
	if err := p.send("media.join", map[string]any{}); err != nil {
		p.close()
		return nil, errors.New("media_join")
	}
	return p, nil
}
func (p *peer) prepare(maxPeers int) error {
	engine := &webrtc.MediaEngine{}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2, SDPFmtpLine: "minptime=10;useinbandfec=1"}, PayloadType: 111}, webrtc.RTPCodecTypeAudio); err != nil {
		return err
	}
	if err := engine.RegisterCodec(webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000, RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack"}, {Type: "nack", Parameter: "pli"}, {Type: "ccm", Parameter: "fir"}}}, PayloadType: 96}, webrtc.RTPCodecTypeVideo); err != nil {
		return err
	}
	pc, err := webrtc.NewAPI(webrtc.WithMediaEngine(engine)).NewPeerConnection(webrtc.Configuration{BundlePolicy: webrtc.BundlePolicyMaxBundle, SDPSemantics: webrtc.SDPSemanticsUnifiedPlan})
	if err != nil {
		return err
	}
	p.pc = pc
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		var v *webrtc.ICECandidateInit
		if c != nil {
			init := c.ToJSON()
			v = &init
		}
		if p.send("media.ice", map[string]any{"mediaPeerId": p.peerID, "candidate": v}) != nil {
			p.fail(errors.New("ice_send"))
		}
	})
	pc.OnTrack(func(track *webrtc.TrackRemote, receiver *webrtc.RTPReceiver) {
		p.workers.Add(1)
		go func() {
			defer p.workers.Done()
			for {
				if _, _, err := track.ReadRTP(); err != nil {
					return
				}
				if track.Kind() == webrtc.RTPCodecTypeAudio {
					p.audio.Add(1)
				} else {
					p.video.Add(1)
				}
			}
		}()
	})
	audio, err := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}, uuid.NewString(), "fixture")
	if err != nil {
		return err
	}
	video, err := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90000}, uuid.NewString(), "fixture")
	if err != nil {
		return err
	}
	for _, track := range []*webrtc.TrackLocalStaticSample{audio, video} {
		transceiver, err := pc.AddTransceiverFromTrack(track, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionSendrecv})
		if err != nil {
			return err
		}
		p.source = append(p.source, transceiver)
		sender := transceiver.Sender()
		p.workers.Add(1)
		go func() {
			defer p.workers.Done()
			buffer := make([]byte, 1500)
			for {
				if _, _, err := sender.Read(buffer); err != nil {
					return
				}
			}
		}()
	}
	for i := 0; i < maxPeers-1; i++ {
		for _, kind := range []webrtc.RTPCodecType{webrtc.RTPCodecTypeAudio, webrtc.RTPCodecTypeVideo} {
			if _, err := pc.AddTransceiverFromKind(kind, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
				return err
			}
		}
	}
	p.workers.Add(1)
	go func() {
		defer p.workers.Done()
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-p.done:
				return
			case <-ticker.C:
				_ = audio.WriteSample(media.Sample{Data: []byte{0xf8, 0xff, 0xfe}, Duration: 20 * time.Millisecond})
				_ = video.WriteSample(media.Sample{Data: []byte{0x10, 0, 0, 0x9d, 0x01, 0x2a, 0x40, 0x01, 0xb4, 0, 0}, Duration: 20 * time.Millisecond})
			}
		}
	}()
	return p.offer()
}
func (p *peer) offer() error {
	if p.pending {
		p.dirty = true
		return nil
	}
	offer, err := p.pc.CreateOffer(nil)
	if err != nil {
		return err
	}
	if err = p.pc.SetLocalDescription(offer); err != nil {
		return err
	}
	publications := []map[string]string{}
	for index, transceiver := range p.source {
		source := "microphone"
		if index == 1 {
			source = "camera"
		}
		publications = append(publications, map[string]string{"mid": transceiver.Mid(), "source": source, "trackId": transceiver.Sender().Track().ID()})
	}
	p.negotiation = uuid.NewString()
	p.pending = true
	p.dirty = false
	return p.send("media.offer", map[string]any{"mediaPeerId": p.peerID, "negotiationId": p.negotiation, "sdp": offer.SDP, "publications": publications})
}
func (p *peer) loop() error {
	for {
		var event envelope
		if err := p.socket.ReadJSON(&event); err != nil {
			return errors.New("socket_read")
		}
		if event.ConferenceID != p.room {
			return errors.New("room_scope")
		}
		var data struct {
			MediaPeerID   string                   `json:"mediaPeerId"`
			MaxPeers      int                      `json:"maxPeers"`
			NegotiationID string                   `json:"negotiationId"`
			SDP           string                   `json:"sdp"`
			Candidate     *webrtc.ICECandidateInit `json:"candidate"`
			Code          string                   `json:"code"`
		}
		if json.Unmarshal(event.Data, &data) != nil {
			return errors.New("event_decode")
		}
		switch event.Type {
		case "media.joined":
			if p.pc != nil || data.MaxPeers < 2 || data.MaxPeers > 32 {
				return errors.New("joined")
			}
			p.peerID = data.MediaPeerID
			if err := p.prepare(data.MaxPeers); err != nil {
				return errors.New("prepare")
			}
		case "media.answer":
			if data.MediaPeerID != p.peerID || data.NegotiationID != p.negotiation {
				return errors.New("answer_scope")
			}
			if err := p.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: data.SDP}); err != nil {
				return errors.New("answer_apply")
			}
			for _, candidate := range p.remoteICE {
				if p.pc.AddICECandidate(candidate) != nil {
					return errors.New("buffered_ice")
				}
			}
			p.remoteICE = nil
			if err := p.send("media.ready", map[string]string{"mediaPeerId": p.peerID, "negotiationId": p.negotiation}); err != nil {
				return errors.New("ready_send")
			}
			p.negotiations.Add(1)
			p.pending = false
			if p.dirty {
				if err := p.offer(); err != nil {
					return err
				}
			}
		case "media.ice":
			if data.MediaPeerID != p.peerID {
				continue
			}
			candidate := webrtc.ICECandidateInit{}
			if data.Candidate != nil {
				candidate = *data.Candidate
			}
			if p.pc == nil || p.pc.RemoteDescription() == nil {
				p.remoteICE = append(p.remoteICE, candidate)
			} else if p.pc.AddICECandidate(candidate) != nil {
				return errors.New("remote_ice")
			}
		case "media.renegotiate":
			if data.MediaPeerID == p.peerID && p.pc != nil {
				if err := p.offer(); err != nil {
					return err
				}
			}
		case "error", "media.error":
			return errors.New("signaling_error_" + data.Code)
		}
	}
}
func (p *peer) close() {
	p.once.Do(func() { close(p.done); _ = p.send("media.leave", map[string]any{}); _ = p.socket.Close() })
	// The loop owns pc creation; drain it before reading pc or waiting for its RTP workers.
	<-p.readDone
	if p.pc != nil {
		_ = p.pc.Close()
	}
}

func run() error {
	base := os.Getenv("MEETSPACE_PROBE_API")
	if !strings.HasPrefix(base, "http://meetspace-ios-contract-") {
		return errors.New("isolated_network_required")
	}
	stage = "accounts"
	tokenA, err := account(base)
	if err != nil {
		return err
	}
	tokenB, err := account(base)
	if err != nil {
		return err
	}
	var room struct {
		Item struct {
			ID         string `json:"id"`
			InviteCode string `json:"inviteCode"`
		} `json:"item"`
	}
	stage = "create"
	if err = request(base, tokenA, "POST", "/conferences", map[string]any{"title": "Pion synthetic RTP fixture", "waitingRoomEnabled": false}, &room); err != nil {
		return err
	}
	var participantB string
	for _, token := range []string{tokenA, tokenB} {
		var membership struct {
			Item struct {
				ID string `json:"id"`
			} `json:"item"`
		}
		if err = request(base, token, "POST", "/conferences/"+room.Item.ID+"/join", map[string]string{"inviteCode": room.Item.InviteCode}, &membership); err != nil {
			return err
		}
		if token == tokenB {
			participantB = membership.Item.ID
		}
	}
	if err = request(base, tokenA, "POST", "/conferences/"+room.Item.ID+"/start", map[string]any{}, nil); err != nil {
		return err
	}
	stage = "moderation_enforcement"
	moderationPath := "/conferences/" + room.Item.ID + "/participants/" + participantB + "/moderation"
	if err = request(base, tokenA, "POST", moderationPath, map[string]any{"action": "camera", "blocked": true}, nil); err != nil {
		return err
	}
	blocked, err := connect(base, tokenB, room.Item.ID)
	if err != nil {
		return err
	}
	var denied error
	select {
	case denied = <-blocked.failures:
	case <-time.After(10 * time.Second):
	}
	blocked.close()
	blocked.workers.Wait()
	if denied == nil || denied.Error() != "signaling_error_media_policy_blocked" {
		return errors.New("blocked_source_not_rejected")
	}
	if err = request(base, tokenA, "POST", moderationPath, map[string]any{"action": "camera", "blocked": false}, nil); err != nil {
		return err
	}
	fmt.Println("PASS synthetic SFU policy: publishing a moderator-blocked camera was rejected")
	for cycle := 1; cycle <= 3; cycle++ {
		stage = fmt.Sprintf("cycle_%d_connect", cycle)
		a, err := connect(base, tokenA, room.Item.ID)
		if err != nil {
			return err
		}
		b, err := connect(base, tokenB, room.Item.ID)
		if err != nil {
			a.close()
			return err
		}
		stage = fmt.Sprintf("cycle_%d_rtp", cycle)
		started := time.Now()
		deadline := time.Now().Add(25 * time.Second)
		success := false
		for time.Now().Before(deadline) {
			select {
			case err = <-a.failures:
			case err = <-b.failures:
			default:
			}
			if err != nil {
				break
			}
			if a.audio.Load() >= 10 && a.video.Load() >= 10 && b.audio.Load() >= 10 && b.video.Load() >= 10 && (cycle != 1 || time.Since(started) > 6*time.Second) {
				success = true
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		a.close()
		b.close()
		stopped := make(chan struct{})
		go func() { a.workers.Wait(); b.workers.Wait(); close(stopped) }()
		select {
		case <-stopped:
		case <-time.After(5 * time.Second):
			return errors.New("local_resources_not_released")
		}
		if err != nil {
			return err
		}
		if !success {
			return errors.New("rtp_timeout")
		}
		fmt.Printf("PASS synthetic SFU cycle %d: both peers received Opus and VP8 RTP; negotiations=%d/%d; local workers released\n", cycle, a.negotiations.Load(), b.negotiations.Load())
		time.Sleep(time.Second)
	}
	stage = "finish"
	return request(base, tokenA, "POST", "/conferences/"+room.Item.ID+"/finish", map[string]any{}, nil)
}
func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- run() }()
	select {
	case err := <-result:
		if err != nil {
			fmt.Println("FAIL synthetic SFU probe:", stage, err.Error())
			os.Exit(1)
		}
	case <-ctx.Done():
		fmt.Println("FAIL synthetic SFU probe: deadline")
		os.Exit(1)
	}
}
